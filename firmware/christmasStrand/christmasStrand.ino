#include <Adafruit_NeoPixel.h>
#ifdef __AVR__
#include <avr/power.h>
#endif

#define PIN 6
#define TIMEOUT 15

unsigned long t0 = millis();
unsigned long second_counter = millis();
uint8_t idle_counter = 0;

uint8_t simpleLightBits = 0xf;

void setup() {
  // This is for Trinket 5V 16MHz, you can remove these three lines if you are not using a Trinket
#if defined (__AVR_ATtiny85__)
  if (F_CPU == 16000000) clock_prescale_set(clock_div_1);
#endif
  // End of trinket special code
  pinMode(2, OUTPUT);
  pinMode(3, OUTPUT);
  pinMode(4, OUTPUT);
  pinMode(5, OUTPUT);

  // initialize the second counter
  second_counter = millis();

  set_on();

  //Reserve space for the inputString and buffer
  
  Serial.begin(115200);
}

void set_on() {
  digitalWrite(2, HIGH);
  digitalWrite(3, HIGH);
  digitalWrite(4, HIGH);
  digitalWrite(5, HIGH);
}

void serialDelay(uint8_t wait) {
  // do the timery things
  t0 = millis();

  while (((millis() - t0) < wait)) {
    
    // Add some time stuff
    if ((millis() - second_counter) > 1000) {
      idle_counter += 1;
      second_counter = millis();

      if (idle_counter > TIMEOUT) {
        set_on();
      }
    }

    // Check for new serial data
    serialEvent();
    setSimpleLights(simpleLightBits);
  }
}

void serialEvent() {

  while (Serial.available()) {
    // reset the idle timer
    idle_counter = 0;
    // get the new byte:
    simpleLightBits = Serial.read();   
  }

  if (idle_counter == 0) {
    Serial.write(simpleLightBits);
    Serial.write(0xDB);
  }

}

void setSimpleLights(uint8_t inByte) {
    digitalWrite(2, bitRead(inByte, 0));
    digitalWrite(3, bitRead(inByte, 1));
    digitalWrite(4, bitRead(inByte, 2));
    digitalWrite(5, bitRead(inByte, 3));
}

void loop() {
  serialDelay(16);
}
