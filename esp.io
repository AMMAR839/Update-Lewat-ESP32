#include <WiFi.h>
#include <WiFiClientSecure.h>
#include <PubSubClient.h>

#include <ArduinoJson.h>
#include "mbedtls/base64.h"

// WiFi
const char* ssid = "STECHOQ PLUSS+";
const char* pass = "stechoqbisa24";

// HiveMQ Cloud
const char* mqttHost = "e4513f5480de42a8a1f9841a58dc2912.s1.eu.hivemq.cloud";
const int   mqttPort = 8883;
const char* mqttUser = "ESP32_1";
const char* mqttPass = "Enter123";

// Device
const char* DEVICE_ID = "esp32_001";

// Topics
String topicLog    = String("devices/") + DEVICE_ID + "/log";
String topicStatus = String("devices/") + DEVICE_ID + "/status";
String topicCmd    = String("devices/") + DEVICE_ID + "/cmd";
String topicFw     = String("devices/") + DEVICE_ID + "/fw";
String topicFwAck  = String("devices/") + DEVICE_ID + "/fw_ack";

// UART pins
static const int UART_RX_PIN = 4;   // STM32 PA2 -> ESP32 GPIO4
static const int UART_TX_PIN = 25;  // ESP32 GPIO25 -> STM32 PA3
static const uint32_t UART_BAUD = 115200;

WiFiClientSecure net;
PubSubClient mqtt(net);

String uartLine;

volatile bool cmdPending = false;
String pendingCmd;

volatile bool fwPending = false;
String pendingFwJson;

bool otaActive = false;
uint32_t ota_expected_crc = 0;

void connectWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(ssid, pass);
  unsigned long t0 = millis();
  while (WiFi.status() != WL_CONNECTED) {
    delay(300);
    if (millis() - t0 > 20000) ESP.restart();
  }
}

void connectMQTT() {
  while (!mqtt.connected()) {
    mqtt.connect("esp32_001", mqttUser, mqttPass);
    delay(300);
  }
  mqtt.subscribe(topicCmd.c_str(), 1);
  mqtt.subscribe(topicFw.c_str(), 1);
  mqtt.publish(topicStatus.c_str(), "online", true);
}

void publishLog(const String& s) {
  String x = s;
  x.trim();
  if (!x.length()) return;
  if (x.length() > 900) x = x.substring(0, 900);
  mqtt.publish(topicLog.c_str(), x.c_str(), false);
}

void publishAckOK(int seq) {
  String msg = "OK " + String(seq);
  mqtt.publish(topicFwAck.c_str(), msg.c_str(), false); // retain = false
}

void publishAckERR(int seq, const char* why) {
  String msg = "ERR " + String(seq) + " " + String(why);
  mqtt.publish(topicFwAck.c_str(), msg.c_str(), false); // retain = false
}

bool pollUartOneLine(String &outLine) {
  while (Serial2.available()) {
    char c = (char)Serial2.read();
    if (c == '\n') {
      outLine = uartLine;
      uartLine = "";
      outLine.trim();
      if (outLine.length()) publishLog(outLine);
      return outLine.length() > 0;
    } else if (c != '\r') {
      uartLine += c;
      if (uartLine.length() > 950) {
        publishLog(uartLine);
        uartLine = "";
      }
    }
  }
  return false;
}

bool waitForOkOrErr(uint32_t timeoutMs, bool &isOk) {
  uint32_t t0 = millis();
  while (millis() - t0 < timeoutMs) {
    mqtt.loop();
    String line;
    if (pollUartOneLine(line)) {
      if (line == "OK") { isOk = true; return true; }
      if (line.startsWith("ERR")) { isOk = false; return true; }
    }
    delay(1);
  }
  return false;
}

bool b64decodeToBuf(const char* b64, uint8_t* outBuf, size_t outMax, size_t &outLen) {
  size_t b64Len = strlen(b64);
  size_t olen = 0;
  int ret = mbedtls_base64_decode(outBuf, outMax, &olen,
                                 (const unsigned char*)b64, b64Len);
  if (ret != 0) return false;
  outLen = olen;
  return true;
}

void onMqttMsg(char* topic, byte* payload, unsigned int len) {
  String t = topic;
  String s;
  s.reserve(len + 2);
  for (unsigned int i = 0; i < len; i++) s += (char)payload[i];
  s.trim();

  if (t == topicCmd) {
    if (otaActive) return;
    pendingCmd = s;
    cmdPending = true;
    return;
  }

  if (t == topicFw) {
    pendingFwJson = s;
    fwPending = true;
    return;
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);

  Serial2.begin(UART_BAUD, SERIAL_8N1, UART_RX_PIN, UART_TX_PIN);

  connectWiFi();

  net.setInsecure();
  mqtt.setServer(mqttHost, mqttPort);
  mqtt.setCallback(onMqttMsg);

  mqtt.setBufferSize(8192);

  mqtt.publish(topicStatus.c_str(), "booting", true);
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) connectWiFi();
  if (!mqtt.connected()) connectMQTT();
  mqtt.loop();

  // IMPORTANT: jangan drain UART kalau OTA aktif (biar OK/ERR nggak “ketelan”)
    // Jangan "curi" OK saat OTA
  if (!otaActive && !fwPending) {
    String dummy;
    pollUartOneLine(dummy);
  }


  // CMD mode
  if (cmdPending && !otaActive) {
    cmdPending = false;
    String cmd = pendingCmd;

    publishLog("CMD_RECEIVED: " + cmd);

    // bersihin RX buffer
    while (Serial2.available()) (void)Serial2.read();
    uartLine = "";

    Serial2.print(cmd);
    Serial2.print("\n");      // pakai \n aja
    Serial2.flush();
  }

  // FW / OTA mode
  if (fwPending) {
    fwPending = false;

    DynamicJsonDocument doc(12288);
    DeserializationError err = deserializeJson(doc, pendingFwJson);
    if (err) {
      publishLog(String("FW_JSON_ERR: ") + err.c_str());
      publishAckERR(0, "JSON_PARSE");
      return;
    }

    int seq = doc["seq"] | -1;
    const char* typ = doc["t"] | "";
    if (seq < 0 || strlen(typ) == 0) {
      publishAckERR(seq < 0 ? 0 : seq, "BAD_FIELDS");
      return;
    }

    if (strcmp(typ, "BEGIN") == 0) {
      otaActive = true;

      uint32_t size = doc["size"] | 0;
      ota_expected_crc = doc["crc32"] | 0;

      while (Serial2.available()) (void)Serial2.read();
      uartLine = "";

      Serial2.printf("BEGIN %lu\n", (unsigned long)size);
      Serial2.flush();

      bool okFlag = false;
      if (!waitForOkOrErr(15000, okFlag) || !okFlag) { publishAckERR(seq, "BEGIN_NO_OK1"); otaActive=false; return; }
      if (!waitForOkOrErr(30000, okFlag) || !okFlag) { publishAckERR(seq, "BEGIN_NO_OK2"); otaActive=false; return; }

      publishAckOK(seq);
      return;
    }

    if (strcmp(typ, "DATA") == 0) {
      if (!otaActive) { publishAckERR(seq, "NOT_IN_OTA"); return; }

      uint32_t off = doc["off"] | 0;
      const char* b64 = doc["b64"] | "";

      uint8_t raw[1024];
      size_t rawLen = 0;
      if (!b64decodeToBuf(b64, raw, sizeof(raw), rawLen) || rawLen == 0) {
        publishAckERR(seq, "B64_DECODE");
        return;
      }

      Serial2.printf("DATA %lu %lu\n", (unsigned long)off, (unsigned long)rawLen);
      Serial2.write(raw, rawLen);
      Serial2.flush();

      bool okFlag = false;
      if (!waitForOkOrErr(20000, okFlag) || !okFlag) { publishAckERR(seq, "DATA_NO_OK"); return; }

      publishAckOK(seq);
      return;
    }

    if (strcmp(typ, "END") == 0) {
      if (!otaActive) { publishAckERR(seq, "NOT_IN_OTA"); return; }

      Serial2.printf("END %lu\n", (unsigned long)ota_expected_crc);
      Serial2.flush();

      bool okFlag = false;
      if (!waitForOkOrErr(20000, okFlag) || !okFlag) { publishAckERR(seq, "END_NO_OK"); return; }

      publishAckOK(seq);
      otaActive = false;
      return;
    }

    publishAckERR(seq, "UNKNOWN_T");
  }
}
