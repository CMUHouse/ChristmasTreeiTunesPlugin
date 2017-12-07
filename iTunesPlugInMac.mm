//
// File:       iTunesPlugInMac.mm
//
// Abstract:   Visual plug-in for iTunes on MacOS
//
// Version:    2.0
//
// Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple Inc. ( "Apple" )
//             in consideration of your agreement to the following terms, and your use,
//             installation, modification or redistribution of this Apple software
//             constitutes acceptance of these terms.  If you do not agree with these
//             terms, please do not use, install, modify or redistribute this Apple
//             software.
//
//             In consideration of your agreement to abide by the following terms, and
//             subject to these terms, Apple grants you a personal, non - exclusive
//             license, under Apple's copyrights in this original Apple software ( the
//             "Apple Software" ), to use, reproduce, modify and redistribute the Apple
//             Software, with or without modifications, in source and / or binary forms;
//             provided that if you redistribute the Apple Software in its entirety and
//             without modifications, you must retain this notice and the following text
//             and disclaimers in all such redistributions of the Apple Software. Neither
//             the name, trademarks, service marks or logos of Apple Inc. may be used to
//             endorse or promote products derived from the Apple Software without specific
//             prior written permission from Apple.  Except as expressly stated in this
//             notice, no other rights or licenses, express or implied, are granted by
//             Apple herein, including but not limited to any patent rights that may be
//             infringed by your derivative works or by other works in which the Apple
//             Software may be incorporated.
//
//             The Apple Software is provided by Apple on an "AS IS" basis.  APPLE MAKES NO
//             WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION THE IMPLIED
//             WARRANTIES OF NON - INFRINGEMENT, MERCHANTABILITY AND FITNESS FOR A
//             PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND OPERATION
//             ALONE OR IN COMBINATION WITH YOUR PRODUCTS.
//
//             IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL OR
//             CONSEQUENTIAL DAMAGES ( INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//             SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//             INTERRUPTION ) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION, MODIFICATION
//             AND / OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED AND WHETHER
//             UNDER THEORY OF CONTRACT, TORT ( INCLUDING NEGLIGENCE ), STRICT LIABILITY OR
//             OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
// Copyright © 2001-2011 Apple Inc. All Rights Reserved.
//

//-------------------------------------------------------------------------------------------------
//	includes
//-------------------------------------------------------------------------------------------------

#import "iTunesPlugIn.h"

#import <AppKit/AppKit.h>
#import <OpenGL/gl.h>
#import <OpenGL/glu.h>
#import <string.h>
#include <stdio.h>
#import "ORSSerialPort.h"
#import "ORSSerialPortManager.h"
#import "GCDAsyncUdpSocket.h"

#include <vector>
#include <algorithm>
#include <numeric>
#include <array>
#include <deque>
#include <bitset>

#define FORCE_LIGHTS_OFF 0

using namespace std;

//-------------------------------------------------------------------------------------------------
//	constants, etc.
//-------------------------------------------------------------------------------------------------

#define kTVisualPluginName              CFSTR("Christmas Visualizer")

//-------------------------------------------------------------------------------------------------
//	exported function prototypes
//-------------------------------------------------------------------------------------------------

extern "C" OSStatus iTunesPluginMainMachO( OSType inMessage, PluginMessageInfo *inMessageInfoPtr, void *refCon ) __attribute__((visibility("default")));

#if USE_SUBVIEW
//-------------------------------------------------------------------------------------------------
//	VisualView
//-------------------------------------------------------------------------------------------------

@interface VisualView : NSView <ORSSerialPortDelegate, GCDAsyncUdpSocketDelegate>
{
	VisualPluginData *	_visualPluginData;
}

@property (nonatomic, assign) VisualPluginData * visualPluginData;

-(void)drawRect:(NSRect)dirtyRect;
- (BOOL)acceptsFirstResponder;
- (BOOL)becomeFirstResponder;
- (BOOL)resignFirstResponder;
-(void)keyDown:(NSEvent *)theEvent;

@property (nonatomic, assign) BOOL bAttemptedSerialInit;
@property (nonatomic, strong) ORSSerialPort * serialPort;

@property (strong, nonatomic) dispatch_queue_t socket_queue;
@property (strong, nonatomic) GCDAsyncUdpSocket* udp_socket;

- (void)cleanupSerialPort;
- (void)setupSerialPort;

@end

#endif	// USE_SUBVIEW

static const size_t kNumTreeBits = 3;
static const size_t kNumTreeProgrammableLights = 75;
static const size_t kLPFSize = 10;


typedef std::vector<UInt8> SpectrumData;
typedef std::array<float, kNumTreeBits> OutputLevels;
typedef std::bitset<kNumTreeBits> TreeDisplayBits;
typedef std::deque<OutputLevels> OutputLevelsQueue;

static const bool kEmitLEDRibbonIntensity = true;

SpectrumData scaleSpectrumData(const SpectrumData& srcData,
                               size_t srcStart, size_t srcLength,
                               size_t dstLength)
{
    SpectrumData outData;
    outData.reserve(dstLength);
    
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceGray();
    
    CGContextRef spectrumCtx = CGBitmapContextCreate((void*)(srcData.data() + srcStart),
                                                     srcLength, 1,
                                                     8, srcLength,
                                                     colorSpace, kCGImageAlphaNone);
    
    CGContextRef dstCtx = CGBitmapContextCreate(NULL, dstLength, 1, 8, dstLength, colorSpace, kCGImageAlphaNone);
    
    if (spectrumCtx && dstCtx) {
        
        CGImageRef img = CGBitmapContextCreateImage(spectrumCtx);

        CGContextSetInterpolationQuality(dstCtx, kCGInterpolationLow);
        CGContextDrawImage(dstCtx, CGRectMake(0, 0, dstLength, 1), img);
        
        UInt8* dstCtxBytes = (UInt8*)CGBitmapContextGetData(dstCtx);
        outData.assign(dstCtxBytes, dstCtxBytes + dstLength);
        
        if (img) {
            CFRelease(img);
        }
    }
    
    if (spectrumCtx) {
        CFRelease(spectrumCtx);
    }
    
    if (colorSpace) {
        CFRelease(colorSpace);
    }

    if (dstCtx) {
        CFRelease(dstCtx);
    }
    
    if (outData.size() < dstLength) {
        outData.resize(dstLength);
    }
    
    return outData;
}

OutputLevels outputLevelsQueueAverage(const OutputLevelsQueue& queue) {
    
    OutputLevels avgLevels;
    for (int i=0; i<kNumTreeBits; i++) {
        avgLevels[i]=0;
    }
    
    if (queue.size()) {
        for (auto lev : queue) {
            for (int i=0; i<kNumTreeBits; i++) {
                avgLevels[i] += lev[i];
            }
        }
        for (int i=0; i<kNumTreeBits; i++) {
            avgLevels[i] /= queue.size();
        }
    }
    return avgLevels;
}

OutputLevels outputLevelsQueueMax(const OutputLevelsQueue& queue) {
    
    OutputLevels maxLevels;
    for (int i=0; i<kNumTreeBits; i++) {
        maxLevels[i]=0;
    }
    
    if (queue.size()) {
        for (auto lev : queue) {
            for (int i=0; i<kNumTreeBits; i++) {
                maxLevels[i] = MAX(lev[i], maxLevels[i]);
            }
        }
    }
    return maxLevels;
}

static uint8_t GetTreeByte(const TreeDisplayBits& treeBits)
{
    uint8_t r = 0;
    for (int i=0; i<kNumTreeBits; i++) {
        if (treeBits[i]) {
            r = r | (1<<(i+1));
        }
    }
    return r;
}

//-------------------------------------------------------------------------------------------------
//	DrawVisual
//-------------------------------------------------------------------------------------------------
//
void DrawVisualView_( VisualPluginData * visualPluginData, ORSSerialPort* serialPort, NSRect viewBounds )
{

    vector<UInt8> leftSpectrumData, rightSpectrumData;
    leftSpectrumData.reserve(kVisualNumSpectrumEntries);
    rightSpectrumData.reserve(kVisualNumSpectrumEntries);
    leftSpectrumData.assign(visualPluginData->renderData.spectrumData[0],
                            visualPluginData->renderData.spectrumData[0] + kVisualNumSpectrumEntries);
    
    rightSpectrumData.assign(visualPluginData->renderData.spectrumData[1],
                             visualPluginData->renderData.spectrumData[1] + kVisualNumSpectrumEntries);
    
    
    vector<UInt8> spectrumData;
    spectrumData.reserve(kVisualNumSpectrumEntries);
    for (int i=0; i<kVisualNumSpectrumEntries; i++) {
        spectrumData.push_back((leftSpectrumData[i] + rightSpectrumData[i]) / 2);
    }
	
	// this shouldn't happen but let's be safe
	if ( visualPluginData->destView == NULL )
		return;
    
    const uint32_t spectSum = accumulate(spectrumData.begin(), spectrumData.end(), 0);

    size_t fivePercentMax=0;
    {
        uint32_t sumLimit = 0;
        for(int i=spectrumData.size()-1;i>=0;i--){
            sumLimit += spectrumData[i];
            if(sumLimit >= spectSum*0.05){
                fivePercentMax = i;
                break;
            }
        }
    }
	
    size_t fivePercentMin=0;
    {
        uint32_t sumLimit = 0;
        for(int i=0;i<spectrumData.size();i++){
            sumLimit += spectrumData[i];
            if(sumLimit >= spectSum*.05){
                fivePercentMin = i;
                break;
            }
        }
    }
    
    if (fivePercentMax <= fivePercentMin) {
        fivePercentMax = fivePercentMin;
    }

    uint32_t specStart = fivePercentMin;
    uint32_t specWidth = fivePercentMax - fivePercentMin;

    SpectrumData simpleData = scaleSpectrumData(spectrumData, specStart, specWidth, kNumTreeBits);

    SpectrumData smallRibbon = scaleSpectrumData(spectrumData, specStart, specWidth, kNumTreeProgrammableLights/3);
    SpectrumData ribbonData = scaleSpectrumData(smallRibbon, 0, smallRibbon.size(), kNumTreeProgrammableLights);
    
    NSSize viewSize = viewBounds.size;
    CGFloat widthStep = viewSize.width / (CGFloat)spectrumData.size();
    CGFloat heightStep = viewSize.height/512;
    CGFloat widthBase = 10;
    CGFloat heightBase = viewSize.height/4;
    
    if (spectrumData.size() ) {
        CGRect drawRect = viewBounds;
        
        // fill the whole view with black to start
        [[NSColor darkGrayColor] set];
        NSRectFill( drawRect );
        
        NSBezierPath* thePath = [NSBezierPath bezierPath];

        NSPoint pt = NSMakePoint(widthBase,
                                 heightBase + (spectrumData[0] * heightStep));
        [thePath moveToPoint:pt];
        
        for(int i=1;i<fivePercentMin;i++){
            pt = NSMakePoint(widthBase + (i*widthStep),
                             heightBase + (spectrumData[i] * heightStep));
            [thePath lineToPoint:pt];
        }
        [thePath setLineWidth:3];
        [[NSColor blueColor] set];
        [thePath stroke];
        
        thePath = [NSBezierPath bezierPath];
        pt = NSMakePoint(widthBase + (fivePercentMin*widthStep),
                         heightBase + (spectrumData[fivePercentMin] * heightStep));
        [thePath moveToPoint:pt];
        for(int i=fivePercentMin;i<fivePercentMax;i++){
            pt = NSMakePoint(widthBase + i*widthStep,
                             heightBase + (spectrumData[i] * heightStep));
            [thePath lineToPoint:pt];
        }
        [thePath setLineWidth:3];
        [[NSColor greenColor] set];
        [thePath stroke];

        thePath = [NSBezierPath bezierPath];
        pt = NSMakePoint(widthBase + fivePercentMax*widthStep,
                         heightBase + (spectrumData[fivePercentMax] * heightStep));

        [thePath moveToPoint:pt];
        for(int i=fivePercentMax;i<kVisualNumSpectrumEntries;i++){
            pt = NSMakePoint(widthBase + i*widthStep,
                             heightBase + (spectrumData[i] * heightStep));
            [thePath lineToPoint:pt];
        }
        [thePath setLineWidth:3];
        [[NSColor redColor] set];
        [thePath stroke];
        
        thePath = [NSBezierPath bezierPath];
        [thePath moveToPoint:NSMakePoint(10, viewSize.height/4)];
        [thePath lineToPoint:NSMakePoint(viewSize.width, viewSize.height/4)];
        [[NSColor whiteColor] set];
        [thePath stroke];
	
    }

    static BOOL bPrevDidDrawArtwork = NO;
    BOOL bDrawArtwork = NO;
    
    if ( time( NULL ) < visualPluginData->drawInfoTimeOut )
    {
        CGPoint where = CGPointMake( 10, 10 );
        
        // if we have a song title, draw it (prefer the stream title over the regular name if we have it)
        NSString *				theString = NULL;
        
        if ( visualPluginData->streamInfo.streamTitle[0] != 0 )
            theString = [NSString stringWithCharacters:&visualPluginData->streamInfo.streamTitle[1] length:visualPluginData->streamInfo.streamTitle[0]];
        else if ( visualPluginData->trackInfo.name[0] != 0 )
            theString = [NSString stringWithCharacters:&visualPluginData->trackInfo.name[1] length:visualPluginData->trackInfo.name[0]];
        
        if ( theString != NULL )
        {
            NSDictionary *		attrs = [NSDictionary dictionaryWithObjectsAndKeys:[NSColor whiteColor], NSForegroundColorAttributeName, NULL];
            
            [theString drawAtPoint:where withAttributes:attrs];
        }
        
        // draw the artwork
        if ( visualPluginData->currentArtwork != NULL )
        {
            where.y += 40;
            
            [visualPluginData->currentArtwork drawAtPoint:where fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.75];
        }
        
        bDrawArtwork = YES;
    }
    
    OutputLevels outputVals;
    for (int i=0; i<kNumTreeBits; i++) {
        outputVals[i] = simpleData[i]/256.f;
    }
    
    // Compute control bits for simple lights
    TreeDisplayBits dispTreeBits(0);
    bool dispBeatDetected = false;
    bool bSimpleLightsWantSend = false;
    {
        TreeDisplayBits treeBits(0);
        bool beatDetected = false;
        
        static OutputLevelsQueue recentLevelsQueue;
        static OutputLevelsQueue currentLevelsQueue;
        static CFTimeInterval prevTime = 0;
        static std::deque<TreeDisplayBits> prevBits;
        
        static std::deque<uint32_t> recentSpectrumSumQueue(1, 0);
        static std::deque<uint32_t> currentSpectrumSumQueue(1, 0);
        
        static OutputLevels lastSetLevels;
        static OutputLevels lastSetMaxLevels;
        static TreeDisplayBits lastSetTreeBits;
        static bool lastSetBeatDetected;
        
        if (!bPrevDidDrawArtwork && bDrawArtwork) {
            recentLevelsQueue.clear();
            currentLevelsQueue.clear();
            prevBits.clear();
            recentSpectrumSumQueue.clear();
            currentSpectrumSumQueue.clear();
        }
        
        CFTimeInterval currTime = CACurrentMediaTime();
        CFTimeInterval delta = currTime - prevTime;
        
        OutputLevels currLevels = outputLevelsQueueMax(currentLevelsQueue);
        OutputLevels avgRecentLevels = outputLevelsQueueAverage(recentLevelsQueue);
        OutputLevels maxRecentLevels = outputLevelsQueueMax(recentLevelsQueue);
        
        for (int i=0; i<kNumTreeBits; i++) {
            BOOL bAboveAvg = (currLevels[i] >= avgRecentLevels[i]);
            //BOOL bAbsoluteThreshold = currLevels[i] > 0.25;
            BOOL bMinThreshold = currLevels[i] > 0.05;
            
            BOOL trigger = (bAboveAvg && bMinThreshold);// || bAbsoluteThreshold;
            if (trigger) {
                treeBits.set(i);
            }
        }
        
        uint32_t currSpectSum = spectSum;
        if (!recentSpectrumSumQueue.empty() && !currentSpectrumSumQueue.empty())
        {
            uint32_t maxSpectSum = *(std::max_element(recentSpectrumSumQueue.begin(), recentSpectrumSumQueue.end()));
            uint32_t minSpectSum = *(std::min_element(recentSpectrumSumQueue.begin(), recentSpectrumSumQueue.end()));
            uint32_t avgSpectSum = std::accumulate(recentSpectrumSumQueue.begin(), recentSpectrumSumQueue.end(), 0) / recentSpectrumSumQueue.size();
            
            currSpectSum = *(std::max_element(currentSpectrumSumQueue.begin(), currentSpectrumSumQueue.end()));
            
            
            double range = maxSpectSum - minSpectSum;
            double spectOffset = currSpectSum - minSpectSum;
            BOOL bThreshold = spectOffset > 0.6 * range;
            BOOL bAboveAvg = currSpectSum >= avgSpectSum;
            beatDetected = bAboveAvg && bThreshold;

            if (beatDetected) {
                treeBits.set();
            }
            
        }
        
        if ((delta * 1000 >= 150)) {
            
            prevTime = currTime;
            
            recentLevelsQueue.push_front(currLevels);
            if (recentLevelsQueue.size() >= kLPFSize) {
                recentLevelsQueue.pop_back();
            }
            
            recentSpectrumSumQueue.push_front(currSpectSum);
            if (recentSpectrumSumQueue.size() >= 20) {
                recentSpectrumSumQueue.pop_back();
            }
            
            currentLevelsQueue.clear();
            currentSpectrumSumQueue.clear();
            
            lastSetLevels = currLevels;
            lastSetTreeBits = treeBits;
            lastSetMaxLevels = maxRecentLevels;
            lastSetBeatDetected = beatDetected;
            
            bSimpleLightsWantSend = true;
        }
        
        currentLevelsQueue.push_back(outputVals);
        currentSpectrumSumQueue.push_back(spectSum);
        
        dispBeatDetected = lastSetBeatDetected;
        dispTreeBits = lastSetTreeBits;
        
        // Debug Display control levels for simple lights
        if (1) {
            
            [[NSColor whiteColor] set];
            NSRectFill(NSMakeRect(300,100, 160, 100));
            
            if (lastSetBeatDetected) {
                [[NSColor orangeColor] set];
                NSRectFill(NSMakeRect(300, 50, 40, 40));
            }
            
            for(int i=0;i<kNumTreeBits;i++){
                
                BOOL bSet = lastSetTreeBits[i];
                CGFloat height = lastSetLevels[i];
                
                NSColor* color = [NSColor colorWithDeviceRed:(i%3==0) ? 1.0 : 0
                                                       green:(i%3==1) ? 1.0 : 0
                                                        blue:(i%3==2) ? 1.0 : 0
                                                       alpha:1];
                if (!bSet) {
                    color = [NSColor purpleColor];
                }
                
                [color set];
                NSRectFill(NSMakeRect(300+i*40,100, 40, 100 * height));
                
                if (bSet) {
                    NSRectFill(NSMakeRect(300+((i+1)*40),50, 40, 40));
                }
            }
            

        }
        
    }
    
    if (kEmitLEDRibbonIntensity && spectSum > 0) {
        
        static CFTimeInterval prevTime = 0;

        static std::vector<SpectrumData> heldUpData;
        static float maxAvgIntensity = 0;
        static SpectrumData maxSpectrumVals;
        static uint8_t addIntensity = 0;
        
        if (!bPrevDidDrawArtwork && bDrawArtwork) {
            maxAvgIntensity = 0;
            addIntensity = 0;
            heldUpData.clear();
            maxSpectrumVals.clear();
        }
        
        CFTimeInterval currTime = CACurrentMediaTime();
        CFTimeInterval delta = currTime - prevTime;
        
        static SpectrumData lastSetRotatedOutput;
        
        if ((delta * 1000) >= 50 || bSimpleLightsWantSend) {
            
            prevTime = currTime;

            // no intensity can be a full 255 since that byte value is reserved
            SpectrumData outIntensities = ribbonData;
            
            if (heldUpData.size()) {

                heldUpData.push_back(ribbonData);
                size_t numArr = heldUpData.size();
                
                for (int i=0; i<ribbonData.size(); i++) {
                    uint32_t sum = 0;
                    for (auto v : heldUpData ) {
                        sum += v[i];
                    }
                    uint32_t avg = sum / numArr;
                    outIntensities[i] = avg;
                }
            }
            
            uint32_t totalIntensity = std::accumulate(outIntensities.begin(), outIntensities.end(), 0);
            float avgIntensity = (float)totalIntensity / (float)outIntensities.size() / 255.f;
            maxAvgIntensity = MAX(maxAvgIntensity, avgIntensity);
            
            if (avgIntensity >= 0.5 || avgIntensity >= (0.75 * maxAvgIntensity)) {
                addIntensity = 64;
            } else {
                addIntensity = (float)addIntensity * 0.3;
            }
            
            if (addIntensity < 10) {
                addIntensity = 0;
            }
            
            if (maxSpectrumVals.size() == outIntensities.size()) {
                for (int i=0; i<outIntensities.size(); i++) {
                    maxSpectrumVals[i] = MAX(outIntensities[i], maxSpectrumVals[i]);
                }
            } else {
                maxSpectrumVals = SpectrumData(outIntensities);
            }
            
            for (int i=0; i<outIntensities.size(); i++) {
                
                float maxVal = maxSpectrumVals[i];
                maxVal = MAX(maxVal, 16);
                
                float val = (float)outIntensities[i] / maxVal;
                
                if (dispBeatDetected) {
                    val = val * 2;
                }
                
                val = MIN(1.f, MAX(0.f, val));
                uint8_t inten = (val * 64) + addIntensity;
                if (inten == 0xDB) {
                    inten = 0xDA;
                }
                outIntensities[i] = inten;
            }
            
            SpectrumData tmp = outIntensities;
            std::reverse(tmp.begin(),tmp.end());
            
            // add the bits to control the basic lights
            uint8_t treeByte = GetTreeByte(dispTreeBits);
            if (dispBeatDetected) {
                treeByte = treeByte | 0x1;
            }
            
            SpectrumData rotatedOutput;
#if FORCE_LIGHTS_OFF
            for (int i=0; i<150; i++) {
                rotatedOutput.push_back(0xAA);
            }
            treeByte = 0xf;
#else
            NSLog(@"DBS: pushing intensities");
            rotatedOutput.insert(rotatedOutput.end(), tmp.begin(), tmp.end());
            tmp = outIntensities;
            rotatedOutput.insert(rotatedOutput.end(), tmp.begin(), tmp.end());
#endif
            lastSetRotatedOutput = rotatedOutput;
            rotatedOutput.push_back(treeByte);
            // add a footer of 0xDB to say we are done with this command
            rotatedOutput.push_back(0xDB);
            
            if (serialPort) {
                //NSLog(@"DBS: spew: TreeByte %x", treeByte);
                //NSLog(@"DBS: spew: Pushing %ld bytes to serial %@\n", rotatedOutput.size(), serialPort);
            }
            
            NSData* data = [NSData dataWithBytes:rotatedOutput.data() length:rotatedOutput.size() * sizeof(uint8_t)];
            if (serialPort) {
                [serialPort sendData:data];
            }
            
            
#if 0
            GCDAsyncUdpSocket* socket = visualPluginData->subview.udp_socket;
            if (socket && smallRibbon.size() == 25)
            {
             
                std::vector<uint8_t> msg;
                for (int i=0; i<25; i++) {
                    uint8_t a = smallRibbon[i] / 2;
                    if (dispBeatDetected) {
                        a *= 2;
                    }
                    msg.push_back(a);
                    msg.push_back(a);
                    msg.push_back(a);
                }
                NSData* data = [NSData dataWithBytes:msg.data() length:msg.size() * sizeof(uint8_t)];
                [socket sendData:data toHost:@"10.0.1.150" port:2390 withTimeout:1.0 tag:0xDEADBEEF];
            }
#endif
            
            heldUpData.clear();
            
        } else {
            heldUpData.push_back(ribbonData);
        }
        
        
        if (1) {
            
            NSBezierPath* thePath = [NSBezierPath bezierPath];
            widthStep = viewSize.width / (CGFloat)lastSetRotatedOutput.size();
            heightStep = viewSize.height/256;
            NSPoint pt = NSMakePoint(widthBase,
                                     heightBase + (lastSetRotatedOutput[0] * heightStep));
            [thePath moveToPoint:pt];
            for (int i=0; i<lastSetRotatedOutput.size(); i++) {
                pt = NSMakePoint(widthBase + i*widthStep,
                                 heightBase + (lastSetRotatedOutput[i] * heightStep));
                [thePath lineToPoint:pt];
            }
            [[NSColor purpleColor] set];
            [thePath setLineWidth:3];
            [thePath stroke];
            
        }
        
    }
	
    bPrevDidDrawArtwork = bDrawArtwork;

}

void ResetSerialTree( VisualPluginData * visualPluginData )
{
    VisualView* subview = visualPluginData->subview;
    ORSSerialPort* serialPort = subview.serialPort;
    
    if (serialPort) {
        
        std::array<uint8_t, 152> msg;
        
        for (int i=0; i<150; i++) {
            msg[i] = 128;
        }
        msg[150] = 0xf;
        msg[151] = 0xDB;
        
        NSData* data = [NSData dataWithBytes:msg.data() length:msg.size() * sizeof(uint8_t)];
        NSLog(@"DBS: Reseting tree lights to all on");
        [serialPort sendData:data];
    }
    

}

//-------------------------------------------------------------------------------------------------
//	UpdateArtwork
//-------------------------------------------------------------------------------------------------
//
void UpdateArtwork( VisualPluginData * visualPluginData, CFDataRef coverArt, UInt32 coverArtSize, UInt32 coverArtFormat )
{
	// release current image
	visualPluginData->currentArtwork = NULL;
	
	// create 100x100 NSImage* out of incoming CFDataRef if non-null (null indicates there is no artwork for the current track)
	if ( coverArt != NULL )
	{
		visualPluginData->currentArtwork = [[NSImage alloc] initWithData:(__bridge NSData*)coverArt];
		
		[visualPluginData->currentArtwork setSize:CGSizeMake( 100, 100 )];
	}
	
	UpdateInfoTimeOut( visualPluginData );
}

//-------------------------------------------------------------------------------------------------
//	InvalidateVisual
//-------------------------------------------------------------------------------------------------
//
void InvalidateVisual( VisualPluginData * visualPluginData )
{
	(void) visualPluginData;

#if USE_SUBVIEW
	// when using a custom subview, we invalidate it so we get our own draw calls
	[visualPluginData->subview setNeedsDisplay:YES];
#endif
}

//-------------------------------------------------------------------------------------------------
//	CreateVisualContext
//-------------------------------------------------------------------------------------------------
//
OSStatus ActivateVisual( VisualPluginData * visualPluginData, VISUAL_PLATFORM_VIEW destView, OptionBits options )
{
	OSStatus			status = noErr;
    NSRect destBounds = destView.bounds;

	visualPluginData->destView			= destView;
    visualPluginData->destOptions		= options;

	UpdateInfoTimeOut( visualPluginData );

#if USE_SUBVIEW

    destView.autoresizingMask = NSViewHeightSizable | NSViewWidthSizable |
    NSViewMinXMargin | NSViewMinYMargin | NSViewMaxXMargin | NSViewMaxYMargin;
    
	// NSView-based subview
    VisualView* subview = [[VisualView alloc] initWithFrame:destBounds];
    visualPluginData->subview = subview;
	if ( subview != NULL )
	{
		[visualPluginData->subview setVisualPluginData:visualPluginData];
		[destView addSubview:visualPluginData->subview];
	}
	else
	{
		status = memFullErr;
	}

#endif

	return status;
}

//-------------------------------------------------------------------------------------------------
//	MoveVisual
//-------------------------------------------------------------------------------------------------
//
OSStatus MoveVisual( VisualPluginData * visualPluginData, OptionBits newOptions )
{
	visualPluginData->destOptions = newOptions;
    return noErr;
}

//-------------------------------------------------------------------------------------------------
//	DeactivateVisual
//-------------------------------------------------------------------------------------------------
//
OSStatus DeactivateVisual( VisualPluginData * visualPluginData )
{
#if USE_SUBVIEW
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:visualPluginData->subview];
    [visualPluginData->subview cleanupSerialPort];

    
	[visualPluginData->subview removeFromSuperview];
	visualPluginData->subview = NULL;
	visualPluginData->currentArtwork = NULL;
#endif
    

	visualPluginData->destView			= NULL;
	visualPluginData->drawInfoTimeOut	= 0;
	
	return noErr;
}

//-------------------------------------------------------------------------------------------------
//	ResizeVisual
//-------------------------------------------------------------------------------------------------
//
OSStatus ResizeVisual( VisualPluginData * visualPluginData )
{
    NSView* destView = visualPluginData->destView;
    NSRect destBounds = destView.bounds;
    VisualView* subview = visualPluginData->subview;
    subview.frame = destBounds;
    return noErr;
}

void        EnableSerialTree( VisualPluginData * visualPluginData )
{
        VisualView* subview = visualPluginData->subview;
        [subview setupSerialPort];
}

void        DisableSerialTree( VisualPluginData * visualPluginData )
{
    ResetSerialTree(visualPluginData);
    VisualView* subview = visualPluginData->subview;
    [subview cleanupSerialPort];
}

//-------------------------------------------------------------------------------------------------
//	ConfigureVisual
//-------------------------------------------------------------------------------------------------
//
OSStatus ConfigureVisual( VisualPluginData * visualPluginData )
{
	(void) visualPluginData;

	// load nib
	// show modal dialog
	// update settings
	// invalidate

	return noErr;
}

#pragma mark -

#if USE_SUBVIEW

@implementation VisualView

@synthesize visualPluginData = _visualPluginData;

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        [self setupSerialPort];
    }
    return self;
}

- (void)dealloc
{
    [self cleanupSerialPort];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc removeObserver:self];
}

//-------------------------------------------------------------------------------------------------
//	isOpaque
//-------------------------------------------------------------------------------------------------
//
- (BOOL)isOpaque
{
	// your custom views should always be opaque or iTunes will waste CPU time drawing behind you
	return YES;
}

//-------------------------------------------------------------------------------------------------
//	drawRect
//-------------------------------------------------------------------------------------------------
//
-(void)drawRect:(NSRect)dirtyRect
{
	if ( _visualPluginData != NULL )
	{
        DrawVisualView_( _visualPluginData , self.serialPort, self.bounds);
	}
}

//-------------------------------------------------------------------------------------------------
//	acceptsFirstResponder
//-------------------------------------------------------------------------------------------------
//
- (BOOL)acceptsFirstResponder
{
	return YES;
}

- (void)cleanupSerialPort
{
    if (self.serialPort) {
        NSLog(@"DBS: cleaning up serial connection");
        [self.serialPort close];
        self.serialPort.delegate = nil;
        self.serialPort = nil;
    }
}

- (void)setupSerialPort
{
    self.bAttemptedSerialInit = YES;
    
    static ORSSerialPortManager* sSerialMgr = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sSerialMgr = [ORSSerialPortManager sharedSerialPortManager];
    });
    
    if (self.serialPort == nil) {
        
        NSArray* availablePorts = [[ORSSerialPortManager sharedSerialPortManager] availablePorts];
        ORSSerialPort* foundPort = nil;
        NSLog(@"DBS: avaialble serial ports %@", availablePorts);
        for (ORSSerialPort* port in availablePorts) {
            
            NSString* path = port.path;
            
            if ([path hasPrefix:@"/dev/tty.usbserial"] ||
                [path hasPrefix:@"/dev/cu.usbserial"] ||
                [path hasPrefix:@"/dev/tty.usbmodem"] ||
                [path hasPrefix:@"/dev/cu.usbmodem"]) {
                
                foundPort = port;
                break;
            }
        }
        
        if (foundPort) {
            
            NSLog(@"DBS: Christmas Tree Visualizer: found serial port name %@, path %@", foundPort.name, foundPort.path);
            self.serialPort = foundPort;
            if (self.serialPort) {
                self.serialPort.delegate = self;
                self.serialPort.baudRate = [NSNumber numberWithInteger:115200];
                [self.serialPort open];
            }
        } else {
            NSLog(@"DBS: Could not find valid Serial port\n");
        }
        
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(serialPortsWereConnected:) name:ORSSerialPortsWereConnectedNotification object:nil];

    }
    
    self.socket_queue = dispatch_queue_create("socket queue",0);
    self.udp_socket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:self.socket_queue];
    
}

- (void)serialPortsWereConnected:(NSNotificationCenter*)notification
{
    [self setupSerialPort];
}

//-------------------------------------------------------------------------------------------------
//	becomeFirstResponder
//-------------------------------------------------------------------------------------------------
//
- (BOOL)becomeFirstResponder
{
    return YES;
}

//-------------------------------------------------------------------------------------------------
//	resignFirstResponder
//-------------------------------------------------------------------------------------------------
//
- (BOOL)resignFirstResponder
{
	return YES;
}

//-------------------------------------------------------------------------------------------------
//	keyDown
//-------------------------------------------------------------------------------------------------
//
-(void)keyDown:(NSEvent *)theEvent
{
	// Handle key events here.
	// Do not eat the space bar, ESC key, TAB key, or the arrow keys: iTunes reserves those keys.

	// if the 'i' key is pressed, reset the info timeout so that we draw it again
	if ( [[theEvent charactersIgnoringModifiers] isEqualTo:@"i"] )
	{
		UpdateInfoTimeOut( _visualPluginData );
		return;
	}

	// Pass all unhandled events up to super so that iTunes can handle them.
	[super keyDown:theEvent];
}

#pragma mark ORSSerialPortDelegate

- (void)serialPort:(ORSSerialPort *)serialPort didReceiveData:(NSData *)data
{
    if (data.length >= 1) {
        const uint8_t* bytes = (const uint8_t*)data.bytes;
        if (bytes[0] == 0xee || bytes[1] == 0xee) {
            NSLog(@"DBS: Error Received Data (%ld) %x %x", data.length, bytes[0], bytes[1]);
        }
    }
}

- (void)serialPortWasRemovedFromSystem:(ORSSerialPort *)serialPort
{
    [self cleanupSerialPort];
}


@end

#endif	// USE_SUBVIEW

#pragma mark -

//-------------------------------------------------------------------------------------------------
//	GetVisualName
//-------------------------------------------------------------------------------------------------
//
void GetVisualName( ITUniStr255 name )
{
	CFIndex length = CFStringGetLength( kTVisualPluginName );

	name[0] = (UniChar)length;
	CFStringGetCharacters( kTVisualPluginName, CFRangeMake( 0, length ), &name[1] );
}

//-------------------------------------------------------------------------------------------------
//	GetVisualOptions
//-------------------------------------------------------------------------------------------------
//
OptionBits GetVisualOptions( void )
{
	OptionBits		options = (kVisualSupportsMuxedGraphics | kVisualWantsIdleMessages | kVisualWantsConfigure);
	
#if USE_SUBVIEW
	options |= kVisualUsesSubview;
#endif

	return options;
}

//-------------------------------------------------------------------------------------------------
//	iTunesPluginMainMachO
//-------------------------------------------------------------------------------------------------
//
OSStatus iTunesPluginMainMachO( OSType message, PluginMessageInfo * messageInfo, void * refCon )
{
	OSStatus		status;
	
	(void) refCon;
	
	switch ( message )
	{
		case kPluginInitMessage:
			status = RegisterVisualPlugin( messageInfo );
			break;
			
		case kPluginCleanupMessage:
			status = noErr;
			break;
			
		default:
			status = unimpErr;
			break;
	}
	
	return status;
}
