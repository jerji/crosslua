#ifdef QEMU_SIM
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "soc/gpio_reg.h"
#include "soc/gpio_struct.h"
#include "hal/gpio_ll.h"

// The QEMU C3 model leaves the display BUSY GPIO (pin 6) in an unknown
// state. The e-ink driver reads it as LOW (busy) and the X4 Pro's
// UcIdleHigh busy-wait has no timeout — it loops forever. Intercept
// gpio_get_level to return "not busy" for the display pin.
//
// Linked via -Wl,--wrap=gpio_get_level in the QEMU build env.
extern "C" int __real_gpio_get_level(gpio_num_t gpio_num);
extern "C" int __wrap_gpio_get_level(gpio_num_t gpio_num) {
  if (gpio_num == GPIO_NUM_6) return 1;  // always "not busy" in the sim
  return __real_gpio_get_level(gpio_num);
}
#endif