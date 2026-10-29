// QEMU simulator support (linked only by the qemu env via -Wl,--wrap=analogRead).
//
// espressif/qemu does not model the ESP32-C3's SAR ADC, so arduino's
// analogRead() falls into the IDF adc_oneshot busy-wait on the conversion-done
// flag that never gets set -> interrupt-wdt panic at boot (the BatteryMonitor
// reads the battery pin via analogRead). The wrapper returns 0 (0 mV), which
// the battery math treats as 0% — fine for an emulated session.
//
// This file is compiled into every env but is inert without the --wrap link
// flag: __wrap_analogRead is never referenced in non-qemu builds, and it does
// not call __real_analogRead (which would be an unresolved symbol without the
// wrap), so the linker drops it.

#include <Arduino.h>

extern "C" int __wrap_analogRead(uint8_t pin) {
  (void)pin;
  return 0;
}