# STM32F407 OTA via ESP32 + MQTT (HiveMQ) — Bootloader + APP1/APP2

Project ini memungkinkan update firmware STM32F407 menggunakan file `.bin` lewat jalur:

**PC (Python uploader)** → **MQTT (HiveMQ Cloud)** → **ESP32** → **UART2 STM32 Bootloader** → **Flash APP** → **Jump ke APP**

---

## 1) Topologi & Wiring

### Wiring UART (STM32 USART2 ↔ ESP32 Serial2)
| STM32F407 | Fungsi | ESP32 |
|---|---|---|
| PA2 (USART2_TX) | STM32 TX → ESP RX | GPIO4 (RX2) |
| PA3 (USART2_RX) | STM32 RX ← ESP TX | GPIO25 (TX2) |
| GND | Ground | GND |

Baudrate: **115200**, 8N1.

---

## 2) Memory Map (wajib konsisten)
- **Bootloader** di `0x08000000` (Sector 0–3 = 64KB)
- **APP** di `0x08010000` (mulai Sector 4)

> Artinya project APP (APP1/APP2) harus dilink ke `0x08010000`.

---

## 3) MQTT Topics

Dengan `DEVICE_ID = esp32_001`:

| Topic | Arah | Isi |
|---|---|---|
| `devices/esp32_001/log` | ESP32 → MQTT | Log dari STM32/ESP32 (BL_READY, APP_READY, RX, OK/ERR, dll) |
| `devices/esp32_001/cmd` | PC/MQTTX → ESP32 → STM32 | Command text: `PING`, `HELLO`, `ENTER_BL` |
| `devices/esp32_001/fw` | Python → ESP32 | JSON paket firmware (BEGIN/DATA/END) |
| `devices/esp32_001/fw_ack` | ESP32 → Python | ACK text: `OK <seq>` atau `ERR <seq> <reason>` |

---

## 4) Protokol Bootloader (UART)

### Masuk Bootloader
APP menerima command:
- `ENTER_BL` → APP set `boot_magic` → `NVIC_SystemReset()`

Bootloader akan print:
- `BL_READY`

### Update Firmware
1) `BEGIN <size>`
- Bootloader balas:
  - `OK` (parse)
  - `OK` (erase flash APP)

2) `DATA <off> <len>` lalu kirim `<len bytes>`
- Bootloader balas:
  - `OK` tiap chunk sukses

3) `END <crc32>`
- Bootloader balas:
  - `OK` jika CRC cocok dan size pas
- Bootloader **jump** ke APP

---

## 5) Folder & File
- `stm32_bootloader/main.c` → kode bootloader STM32
- `stm32_app1/main.c` → APP1 (PING/HELLO/ENTER_BL + LED)
- `stm32_app2/main.c` → APP2 (contoh perilaku LED berbeda)
- `esp32_bridge/esp32_bridge.ino` → ESP32 MQTT ↔ UART bridge + OTA handler
- `pc_uploader/upload.py` → Python uploader file `.bin`

> Silakan sesuaikan struktur folder sesuai repo kamu.

---

## 6) Setup STM32 (CubeIDE)

### A. Bootloader Project
- Flash origin: default `0x08000000` (biarkan)
- USART2 enabled: PA2/PA3, 115200
- Tambahkan section `.noinit` di linker script (bootloader & app):
```ld
.noinit (NOLOAD) :
{
  . = ALIGN(4);
  *(.noinit*)
  . = ALIGN(4);
} >RAM
