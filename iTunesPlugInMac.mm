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

#include <vector>
#include <algorithm>
#include <numeric>
#include <array>
#include <deque>
#include <bitset>

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

@interface VisualView : NSView
{
	VisualPluginData *	_visualPluginData;
}

@property (nonatomic, assign) VisualPluginData * visualPluginData;

-(void)drawRect:(NSRect)dirtyRect;
- (BOOL)acceptsFirstResponder;
- (BOOL)becomeFirstResponder;
- (BOOL)resignFirstResponder;
-(void)keyDown:(NSEvent *)theEvent;

@property (nonatomic, assign) ORSSerialPort * serialPort;

@end

#endif	// USE_SUBVIEW

static const size_t kNumTreeBits = 4;
static const size_t kLPFSize = 10;


typedef std::vector<UInt8> SpectrumData;
typedef std::array<float, kNumTreeBits> OutputLevels;
typedef std::bitset<kNumTreeBits> TreeDisplayBits;
typedef std::deque<OutputLevels> OutputLevelsQueue;

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

        CGContextSetInterpolationQuality(dstCtx, kCGInterpolationHigh);
        CGContextDrawImage(dstCtx, CGRectMake(0, 0, 4, 1), img);

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
    
    OutputLevels avgLevels = {{0,0,0,0}};
    
    if (queue.size()) {
        for (auto lev : queue) {
            for (int i=0; i<4; i++) {
                avgLevels[i] += lev[i];
            }
        }
        for (int i=0; i<kNumTreeBits; i++) {
            avgLevels[i] /= queue.size();
        }
    }
    return avgLevels;
}

//-------------------------------------------------------------------------------------------------
//	DrawVisual
//-------------------------------------------------------------------------------------------------
//
void DrawVisual( VisualPluginData * visualPluginData, ORSSerialPort* serialPort )
{

    long fivePercentMax=0;
	long fivePercentMin=0;
    
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

    for(int i=kVisualNumSpectrumEntries-1;i>=0;i--){
        fivePercentMax += spectrumData[i];
		if(fivePercentMax >= spectSum*0.05){
			fivePercentMax = i;
			break;
		}
	}
	for(int i=0;i<kVisualNumSpectrumEntries;i++){
        fivePercentMin += spectrumData[i];
		if(fivePercentMin >= spectSum*.05){
			fivePercentMin = i;
			break;
		}
	}
    
    if (fivePercentMax <= fivePercentMin) {
        fivePercentMax = fivePercentMin;
    }

    uint32_t specStart = fivePercentMin;
    uint32_t specWidth = fivePercentMax - fivePercentMin;

    SpectrumData simpleData = scaleSpectrumData(spectrumData, specStart, specWidth, 4);
    
    {
        CGRect drawRect = [visualPluginData->destView bounds];
        
        // fill the whole view with black to start
        [[NSColor blackColor] set];
        NSRectFill( drawRect );

        
        NSSize viewSize = [visualPluginData->destView bounds].size;
        
        NSBezierPath* thePath = [NSBezierPath bezierPath];
        NSPoint pt = NSMakePoint(10, viewSize.height/4 + spectrumData[0]);
        
        [thePath moveToPoint:pt];
        for(int i=1;i<fivePercentMin;i++){
            pt = NSMakePoint(10+i*viewSize.width/kVisualNumSpectrumEntries,
                             viewSize.height/4+(spectrumData[i])*viewSize.height/512);
            [thePath lineToPoint:pt];
        }
        [thePath setLineWidth:3];
        [[NSColor blueColor] set];
        [thePath stroke];
        
        thePath = [NSBezierPath bezierPath];
        pt = NSMakePoint(10+fivePercentMin*viewSize.width/kVisualNumSpectrumEntries, viewSize.height/4 + spectrumData[fivePercentMin] );
        [thePath moveToPoint:pt];
        for(int i=fivePercentMin;i<fivePercentMax;i++){
            pt = NSMakePoint(10+i*viewSize.width/kVisualNumSpectrumEntries,viewSize.height/4+spectrumData[i]*viewSize.height/512);
            [thePath lineToPoint:pt];
        }
        [thePath setLineWidth:3];
        [[NSColor greenColor] set];
        [thePath stroke];

        thePath = [NSBezierPath bezierPath];
        pt = NSMakePoint(10+fivePercentMax*viewSize.width/kVisualNumSpectrumEntries, viewSize.height/4 + spectrumData[fivePercentMax]);
        [thePath moveToPoint:pt];
        for(int i=fivePercentMax;i<kVisualNumSpectrumEntries;i++){
            pt = NSMakePoint(10+i*viewSize.width/kVisualNumSpectrumEntries,viewSize.height/4+spectrumData[i]*viewSize.height/512);
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
	
        // should we draw the info/artwork in the bottom-left corner?
        time_t		theTime = time( NULL );
        
        if ( theTime < visualPluginData->drawInfoTimeOut )
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
                
                [visualPluginData->currentArtwork drawAtPoint:where fromRect:NSZeroRect operation:NSCompositeSourceOver fraction:0.75];
            }
        }
        
    }
    
    OutputLevels outputVals;
    for (int i=0; i<kNumTreeBits; i++) {
        outputVals[i] = simpleData[i]/256.f;
    }
    
    static OutputLevelsQueue levelsQueue;

    OutputLevels recentAvgLevels = outputLevelsQueueAverage(levelsQueue);

    TreeDisplayBits disp;
    for (int i=0; i<kNumTreeBits; i++) {
        
        BOOL trigger = outputVals[i] >= recentAvgLevels[i];
        
        if (trigger) {
            disp.set(i);
        }
        
        levelsQueue.push_front(outputVals);
        if (levelsQueue.size() >= kLPFSize) {
            levelsQueue.pop_back();
        }
    }
    
    
    if (1) {
        
        [[NSColor whiteColor] set];
        NSRectFill(NSMakeRect(10,500, 160, 100));
        
        for(int i=0;i<kNumTreeBits;i++){
            
            BOOL bSet = disp[i];
            CGFloat height = outputVals[i];
            
            NSColor* color = [NSColor colorWithDeviceRed:(i%3==0) green:(i%3==1) blue:(i%3==2) alpha:1];
            if (!bSet) {
                color = [NSColor purpleColor];
            }
            
            [color set];
            NSRectFill(NSMakeRect(10+i*40,500, 40, 100 * height));
        }
    }
    
    {
        static CFTimeInterval prevTime = 0;
        static TreeDisplayBits prevDisp;
        
        CFTimeInterval currTime = CACurrentMediaTime();
        CFTimeInterval delta = currTime - prevTime;
        
        if ((delta * 1000 >= 100))
        {
            
            TreeDisplayBits sendBits = disp | prevDisp;            
            char bitData = static_cast<char>(sendBits.to_ulong());
            NSData* data = [NSData dataWithBytes:&bitData length:1];
            if (serialPort) {
                [serialPort sendData:data];
            }

            prevTime = currTime;
            prevDisp.reset();
        } else {
            prevDisp = prevDisp | disp;
        }
    }
	

}

//-------------------------------------------------------------------------------------------------
//	UpdateArtwork
//-------------------------------------------------------------------------------------------------
//
void UpdateArtwork( VisualPluginData * visualPluginData, CFDataRef coverArt, UInt32 coverArtSize, UInt32 coverArtFormat )
{
	// release current image
	[visualPluginData->currentArtwork release];
	visualPluginData->currentArtwork = NULL;
	
	// create 100x100 NSImage* out of incoming CFDataRef if non-null (null indicates there is no artwork for the current track)
	if ( coverArt != NULL )
	{
		visualPluginData->currentArtwork = [[NSImage alloc] initWithData:(NSData*)coverArt];
		
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

	visualPluginData->destView			= destView;
	visualPluginData->destRect			= [destView bounds];
	visualPluginData->destOptions		= options;

	UpdateInfoTimeOut( visualPluginData );

#if USE_SUBVIEW

	// NSView-based subview
	visualPluginData->subview = [[VisualView alloc] initWithFrame:visualPluginData->destRect];
	if ( visualPluginData->subview != NULL )
	{
		[visualPluginData->subview setAutoresizingMask: (NSViewWidthSizable | NSViewHeightSizable)];

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
	visualPluginData->destRect	  = [visualPluginData->destView bounds];
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
	[visualPluginData->subview removeFromSuperview];
	[visualPluginData->subview autorelease];
	visualPluginData->subview = NULL;
	[visualPluginData->currentArtwork release];
	visualPluginData->currentArtwork = NULL;
#endif

	visualPluginData->destView			= NULL;
	visualPluginData->destRect			= CGRectNull;
	visualPluginData->drawInfoTimeOut	= 0;
	
	return noErr;
}

//-------------------------------------------------------------------------------------------------
//	ResizeVisual
//-------------------------------------------------------------------------------------------------
//
OSStatus ResizeVisual( VisualPluginData * visualPluginData )
{
	visualPluginData->destRect = [visualPluginData->destView bounds];

	// note: the subview is automatically resized by iTunes so nothing to do here

	return noErr;
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
        DrawVisual( _visualPluginData , self.serialPort);
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

//-------------------------------------------------------------------------------------------------
//	becomeFirstResponder
//-------------------------------------------------------------------------------------------------
//
- (BOOL)becomeFirstResponder
{
    
    if (_serialPort == nil) {
        
        NSFileManager* fileMgr = [NSFileManager defaultManager];
        NSArray* filePaths = [fileMgr subpathsAtPath:@"/dev"];
        
        NSString* usb_modem_path = nil;
        for (NSString* path in filePaths) {
            
            if ([path hasPrefix:@"tty.usbserial"] || [path hasPrefix:@"tty.usbmodem"]) {
                usb_modem_path = path;
                break;
            }
        }
        
        if (usb_modem_path) {
            
            NSString* serialPortName = [NSString stringWithFormat:@"/dev/%@", usb_modem_path];
            
            NSLog(@"Christmas Tree Visualizer: found serial port name %@", serialPortName);
            
            _serialPort = [ORSSerialPort serialPortWithPath:serialPortName];
            _serialPort.baudRate = [NSNumber numberWithInteger:9600];
            [_serialPort open];
        } else {
            NSLog(@"Christmas Tree Visualizer Error: Could not make a serial port connection");
        }
    }
    
	return YES;
}

//-------------------------------------------------------------------------------------------------
//	resignFirstResponder
//-------------------------------------------------------------------------------------------------
//
- (BOOL)resignFirstResponder
{
    if (_serialPort) {
        [_serialPort close];
    }
    
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
