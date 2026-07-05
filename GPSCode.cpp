#include <Adafruit_GPS.h>
#include <RTClib.h>
#include <Adafruit_MAX1704X.h>
#include <SD.h>
#include <Wire.h>
#include <WiFi.h>
#include <WebServer.h>
#include <esp_sleep.h>
#include <math.h>
#include <string.h>

// --- Pin definitions ---
#define GPS_ENABLE_PIN 12
#define SD_CS_PIN 10
#define STATUS_LED LED_BUILTIN

// --- Timing ---
#define GPS_TIMEOUT_WARM_MS 30000  // warm start: VBACKUP retains ephemeris
#define GPS_TIMEOUT_COLD_MS 90000  // cold start: first boot after battery disconnect
#define WIFI_TIMEOUT_NO_CLIENT 120000
#define WIFI_TIMEOUT_WITH_CLIENT 300000
#define SLEEP_MOVING_S 25
#define SLEEP_STATIONARY_S 180
#define SLEEP_NOFIX_RAMP_S 300
#define SLEEP_NOFIX_MAX_S 600
#define SPEED_THRESHOLD 1.0
#define HYSTERESIS_COUNT 2
#define LOW_BATTERY_V 3.4
#define HDOP_REJECT 10.0

// --- File management ---
#define MAX_FILE_SIZE 2097152  // 2MB file size cap
#define SEQ_DIGITS 5           // LOG_NNNNN_YYYY-MM-DD.CSV

// --- Off-SD safety buffer ---
#define BUF_CAP 40             // recent fixes retained in RTC memory during an SD dropout
#define SD_BEGIN_RETRIES 3     // SD.begin() attempts before declaring a fault

// --- RTC-surviving state ---
RTC_DATA_ATTR uint32_t bootCount = 0;
RTC_DATA_ATTR float lastSpeed = 0;
RTC_DATA_ATTR uint32_t sleepMagic = 0;
RTC_DATA_ATTR uint8_t noFixCount = 0;
RTC_DATA_ATTR uint8_t movingCount = 0;
RTC_DATA_ATTR bool isMoving = false;
RTC_DATA_ATTR uint16_t avgFixTimeMs = 0;
#define SLEEP_MAGIC 0xDEADBEEF

// --- Kalman filter state (survives deep sleep) ---
RTC_DATA_ATTR double kf_lat = 0;      // filtered latitude
RTC_DATA_ATTR double kf_lon = 0;      // filtered longitude
RTC_DATA_ATTR double kf_vlat = 0;     // velocity in lat (deg/s)
RTC_DATA_ATTR double kf_vlon = 0;     // velocity in lon (deg/s)
RTC_DATA_ATTR float kf_p[4] = { 0 };  // covariance diagonal (lat, lon, vlat, vlon)
RTC_DATA_ATTR bool kf_initialized = false;
RTC_DATA_ATTR uint32_t kf_lastFixTime = 0;  // millis of last fix for dt calculation

// --- Off-SD safety buffer state (survives deep sleep in RTC memory) ---
typedef struct {
  int32_t lat_e7;
  int32_t lon_e7;
  float alt_m;
  float speed_kts;
  float cog;
  float hdop;
  float batt_pct;
  float batt_v;
  float charge_rate;
  uint32_t boot;
  uint8_t yr;  // year - 2000
  uint8_t mon;
  uint8_t day;
  uint8_t hr;
  uint8_t minute;
  uint8_t sec;
  uint8_t sats;
  uint8_t flags;
} BufRec;

#define BF_FIX 0x01
#define BF_BATT 0x02
#define BF_RTCLOW 0x04
#define BF_TIME 0x08

RTC_DATA_ATTR BufRec bufRecs[BUF_CAP];
RTC_DATA_ATTR uint16_t bufHead = 0;        // next slot to write
RTC_DATA_ATTR uint16_t bufCount = 0;       // valid records held
RTC_DATA_ATTR uint32_t bufDropped = 0;     // fixes lost to buffer overflow
RTC_DATA_ATTR bool sdFault = false;        // SD sink unavailable on last write
RTC_DATA_ATTR uint32_t sdFaultCycles = 0;  // consecutive cycles SD was unavailable

// --- WiFi AP ---
const char* AP_SSID = "GPS-Logger";
const char* AP_PASS = "gpslogger";

// --- Peripherals ---
Adafruit_GPS GPS(&Serial1);
RTC_PCF8523 rtc;
Adafruit_MAX17048 battery;
WebServer server(80);

bool batteryOK = false;
bool rtcOK = false;
bool sdReady = false;
bool rtcBatteryLow = false;

// --- Log file state ---
uint32_t logFileSeq = 0;
RTC_DATA_ATTR char logFileName[40] = { 0 };  // persists across deep sleep so date/size rotation works

// ============================================================
// Kalman filter for GPS position smoothing
// State: [lat, lon, vlat, vlon]
// Simple 2D constant-velocity model
// ============================================================

void kalmanPredict(float dt) {
  if (!kf_initialized || dt <= 0) return;

  // Predict position from velocity
  kf_lat += kf_vlat * dt;
  kf_lon += kf_vlon * dt;

  // Grow uncertainty — process noise scales with dt
  // Position uncertainty grows with velocity uncertainty * dt
  // Velocity uncertainty grows with acceleration noise
  float accelNoise = 0.000001;                                        // ~0.1m/s² in degrees
  kf_p[0] += kf_p[2] * dt * dt + accelNoise * dt * dt * dt * dt / 4;  // P_lat
  kf_p[1] += kf_p[3] * dt * dt + accelNoise * dt * dt * dt * dt / 4;  // P_lon
  kf_p[2] += accelNoise * dt * dt;                                    // P_vlat
  kf_p[3] += accelNoise * dt * dt;                                    // P_vlon
}

void kalmanUpdate(double measLat, double measLon, float hdop) {
  // Measurement noise from HDOP — higher HDOP = less trust in GPS
  // ~5m accuracy at HDOP 1.0, scaled quadratically
  float measNoise = (5.0 / 111000.0) * hdop;  // convert metres to degrees
  measNoise = measNoise * measNoise;          // variance

  if (!kf_initialized) {
    kf_lat = measLat;
    kf_lon = measLon;
    kf_vlat = 0;
    kf_vlon = 0;
    kf_p[0] = measNoise;
    kf_p[1] = measNoise;
    kf_p[2] = 0.0001;  // initial velocity uncertainty
    kf_p[3] = 0.0001;
    kf_initialized = true;
    return;
  }

  // Kalman gain for position
  float k_lat = kf_p[0] / (kf_p[0] + measNoise);
  float k_lon = kf_p[1] / (kf_p[1] + measNoise);

  // Update position
  double innovLat = measLat - kf_lat;
  double innovLon = measLon - kf_lon;
  kf_lat += k_lat * innovLat;
  kf_lon += k_lon * innovLon;

  // Update velocity estimate from position innovation
  // Only if we have a reasonable dt
  if (kf_lastFixTime > 0) {
    float k_vlat = kf_p[2] / (kf_p[0] + measNoise);
    float k_vlon = kf_p[3] / (kf_p[1] + measNoise);
    kf_vlat += k_vlat * innovLat;
    kf_vlon += k_vlon * innovLon;
    kf_p[2] *= (1 - k_vlat);
    kf_p[3] *= (1 - k_vlon);
  }

  // Update position covariance
  kf_p[0] *= (1 - k_lat);
  kf_p[1] *= (1 - k_lon);
}

// ============================================================
// PCF8523 RTC battery low detection
// ============================================================

bool readRTCBatteryLow() {
  if (!rtcOK) return false;
  Wire.beginTransmission(0x68);
  Wire.write(0x02);
  Wire.endTransmission();
  Wire.requestFrom(0x68, 1);
  if (Wire.available()) {
    uint8_t ctrl3 = Wire.read();
    return (ctrl3 & 0x04) != 0;
  }
  return false;
}

// ============================================================
// SD card helpers
// ============================================================

bool sdBegin() {
  if (sdReady) return true;
  sdReady = SD.begin(SD_CS_PIN);
  if (!sdReady) Serial.println("[SD] begin FAILED");
  return sdReady;
}

void sdEnd() {
  if (sdReady) {
    SD.end();
    sdReady = false;
  }
}

// ============================================================
// Log file rotation — LOG_NNNNN_YYYY-MM-DD.CSV
// With migration of old unpadded filenames
// ============================================================

// Check if a filename has the old unpadded format (LOG_N_ where N has < SEQ_DIGITS digits)
bool isUnpaddedFilename(const char* name) {
  // name is like "LOG_7_2026-03-21.CSV" — digit count between first _ and second _
  const char* p = name;
  if (*p == '/') p++;
  if (strncmp(p, "LOG_", 4) != 0) return false;
  p += 4;
  int digitCount = 0;
  while (*p >= '0' && *p <= '9') {
    digitCount++;
    p++;
  }
  if (*p != '_') return false;
  return digitCount < SEQ_DIGITS;
}

// Extract sequence number from a LOG_ filename
uint32_t extractSeq(const char* name) {
  const char* p = name;
  if (*p == '/') p++;
  if (strncmp(p, "LOG_", 4) != 0) return 0;
  return atol(p + 4);
}

// Build a padded filename from sequence and date suffix
void buildPaddedName(char* buf, size_t bufLen, uint32_t seq, const char* dateSuffix) {
  snprintf(buf, bufLen, "/LOG_%05lu_%s", seq, dateSuffix);
}

uint32_t scanHighestSeqAndMigrate() {
  if (!sdBegin()) return 0;

  File root = SD.open("/");
  if (!root) {
    sdEnd();
    return 0;
  }

  // First pass: collect all LOG_ files, find highest seq, identify unpadded files
  struct FileInfo {
    String name;
    bool needsRename;
  };
  FileInfo fileList[200];
  int fileCount = 0;
  uint32_t highest = 0;

  File entry;
  while ((entry = root.openNextFile()) && fileCount < 200) {
    const char* name = entry.name();
    const char* p = name;
    if (*p == '/') p++;
    if (strncmp(p, "LOG_", 4) == 0) {
      uint32_t seq = extractSeq(p);
      if (seq > highest) highest = seq;
      fileList[fileCount].name = String(name);
      fileList[fileCount].needsRename = isUnpaddedFilename(name);
      fileCount++;
    }
    entry.close();
  }
  root.close();

  // Second pass: rename unpadded files
  int renamed = 0;
  for (int i = 0; i < fileCount; i++) {
    if (!fileList[i].needsRename) continue;

    const char* oldName = fileList[i].name.c_str();
    const char* p = oldName;
    if (*p == '/') p++;

    // Extract seq and date suffix
    uint32_t seq = extractSeq(p);
    // Find the date portion (after the second _)
    const char* seqStart = p + 4;
    const char* dateStart = seqStart;
    while (*dateStart && *dateStart != '_') dateStart++;
    if (*dateStart == '_') dateStart++;

    // Build new name
    char newName[40];
    buildPaddedName(newName, sizeof(newName), seq, dateStart);

    // Only rename if the new name is different
    if (strcmp(oldName, newName) != 0 && strcmp(oldName + 1, newName + 1) != 0) {
      // Ensure old path has leading /
      String oldPath = oldName[0] == '/' ? String(oldName) : String("/") + String(oldName);
      if (SD.rename(oldPath.c_str(), newName)) {
        renamed++;
        Serial.printf("[SD] Renamed %s → %s\n", oldPath.c_str(), newName);
      } else {
        Serial.printf("[SD] Failed to rename %s\n", oldPath.c_str());
      }
    }
  }

  if (renamed > 0) {
    Serial.printf("[SD] Migrated %d files to padded format\n", renamed);
  }

  sdEnd();
  return highest;
}

void buildLogFileName() {
  char dateStr[12] = "NODATE";

  if (rtcOK) {
    DateTime now = rtc.now();
    if (now.year() > 2020) {
      snprintf(dateStr, sizeof(dateStr), "%04d-%02d-%02d",
               now.year(), now.month(), now.day());
    }
  }

  // Check if current file needs rotation
  if (logFileName[0] != 0) {
    // Check date change
    char* datePos = strrchr(logFileName, '_');
    if (datePos && strncmp(datePos + 1, dateStr, strlen(dateStr)) != 0) {
      logFileSeq++;
      snprintf(logFileName, sizeof(logFileName), "/LOG_%05lu_%s.CSV", logFileSeq, dateStr);
      Serial.printf("[LOG] Date changed → %s\n", logFileName);
      return;
    }

    // Check size cap
    if (sdReady || sdBegin()) {
      File f = SD.open(logFileName);
      if (f) {
        unsigned long sz = f.size();
        f.close();
        if (sz >= MAX_FILE_SIZE) {
          logFileSeq++;
          snprintf(logFileName, sizeof(logFileName), "/LOG_%05lu_%s.CSV", logFileSeq, dateStr);
          Serial.printf("[LOG] Size cap reached → %s\n", logFileName);
          return;
        }
      }
    }

    return;  // keep current filename
  }

  // First call — set up filename
  snprintf(logFileName, sizeof(logFileName), "/LOG_%05lu_%s.CSV", logFileSeq, dateStr);
}

// ============================================================
// Sleep interval logic
// ============================================================

int getSleepSeconds() {
  if (noFixCount >= 6) return SLEEP_NOFIX_MAX_S;
  if (noFixCount >= 3) return SLEEP_NOFIX_RAMP_S;
  if (noFixCount > 0) return SLEEP_STATIONARY_S;
  if (isMoving) return SLEEP_MOVING_S;
  return SLEEP_STATIONARY_S;
}

void updateMovementState(float speed, bool hadNoFix) {
  if (speed > SPEED_THRESHOLD) {
    if (hadNoFix) {
      movingCount = HYSTERESIS_COUNT;
      isMoving = true;
    } else {
      if (movingCount < HYSTERESIS_COUNT) movingCount++;
      if (movingCount >= HYSTERESIS_COUNT) isMoving = true;
    }
  } else {
    if (movingCount > 0) movingCount--;
    if (movingCount == 0) isMoving = false;
  }
}

// ============================================================
// Utility
// ============================================================

void blinkLED(int times, int onMs, int offMs) {
  for (int i = 0; i < times; i++) {
    digitalWrite(STATUS_LED, HIGH);
    delay(onMs);
    digitalWrite(STATUS_LED, LOW);
    if (i < times - 1) delay(offMs);
  }
}

bool waitForFix(uint32_t timeoutMs) {
  while (Serial1.available()) {
    Serial1.read();
  }
  GPS.read();

  unsigned long start = millis();
  bool gotFix = false;
  uint32_t nmeaCount = 0;
  uint32_t charCount = 0;

  Serial.printf("[GPS] Waiting for fix (timeout %lums)...\n", timeoutMs);

  while (millis() - start < timeoutMs) {
    char c = GPS.read();
    if (c != 0) charCount++;

    if (GPS.newNMEAreceived()) {
      char* nmea = GPS.lastNMEA();
      nmeaCount++;
      GPS.parse(nmea);

      if (GPS.fix && millis() - start > 1000) {
        if (GPS.HDOP > HDOP_REJECT && GPS.HDOP > 0) {
          continue;
        }

        gotFix = true;
        if (GPS.year > 0 && GPS.month > 0 && GPS.day > 0) {
          unsigned long fixTime = millis() - start;
          if (avgFixTimeMs == 0) {
            avgFixTimeMs = fixTime;
          } else {
            avgFixTimeMs = (avgFixTimeMs * 3 + fixTime) / 4;
          }
          Serial.printf("[GPS] FIX in %lums (avg=%ums) sats=%d hdop=%.1f\n",
                        fixTime, avgFixTimeMs, GPS.satellites, GPS.HDOP);
          return true;
        }
      }
    }

    static unsigned long lastDebug = 0;
    if (millis() - lastDebug > 10000) {
      lastDebug = millis();
      Serial.printf("[GPS] %lus | nmea=%lu fix=%d sats=%d\n",
                    (millis() - start) / 1000, nmeaCount, GPS.fix, GPS.satellites);
    }
  }

  if (charCount == 0) {
    Serial.println("[GPS] ERROR: Zero chars — check wiring (RX=38, EN=12)");
  } else if (!gotFix) {
    Serial.printf("[GPS] TIMEOUT: %lu chars, %lu sentences, no fix\n", charCount, nmeaCount);
  }

  return gotFix;
}

// ============================================================
// Off-SD safety buffer + record formatting
// ============================================================

// Capture the current cycle's GPS/battery state into a compact record.
void fillRec(BufRec* r, bool hasFix, double logLat, double logLon) {
  memset(r, 0, sizeof(*r));
  r->boot = bootCount;

  if (rtcOK) {
    DateTime now = rtc.now();
    if (now.year() > 2020) {
      r->yr = now.year() - 2000;
      r->mon = now.month();
      r->day = now.day();
      r->hr = now.hour();
      r->minute = now.minute();
      r->sec = now.second();
      r->flags |= BF_TIME;
    }
  }
  if (!(r->flags & BF_TIME) && hasFix && GPS.year > 0 && GPS.month > 0 && GPS.day > 0) {
    r->yr = GPS.year;  // Adafruit_GPS already reports the 2-digit (since-2000) year
    r->mon = GPS.month;
    r->day = GPS.day;
    r->hr = GPS.hour;
    r->minute = GPS.minute;
    r->sec = GPS.seconds;
    r->flags |= BF_TIME;
  }

  if (hasFix) {
    r->flags |= BF_FIX;
    r->lat_e7 = (int32_t)lround(logLat * 1e7);
    r->lon_e7 = (int32_t)lround(logLon * 1e7);
    r->alt_m = GPS.altitude;
    r->speed_kts = GPS.speed;
    r->cog = GPS.angle;
    r->sats = (uint8_t)GPS.satellites;
    r->hdop = GPS.HDOP;
  }

  if (batteryOK) {
    r->flags |= BF_BATT;
    r->batt_pct = battery.cellPercent();
    r->batt_v = battery.cellVoltage();
    r->charge_rate = battery.chargeRate();
  }

  if (rtcBatteryLow) r->flags |= BF_RTCLOW;
}

// Render a record as a CSV line identical to the live-logger column layout:
// datetime,lat,lon,alt_m,speed_kts,cog,satellites,hdop,battery_pct,battery_v,charge_rate,rtc_bat_low,fix,boot
void formatRec(char* out, size_t n, const BufRec* r) {
  char ts[24];
  if (r->flags & BF_TIME) {
    snprintf(ts, sizeof(ts), "%04d-%02d-%02dT%02d:%02d:%02d",
             2000 + r->yr, r->mon, r->day, r->hr, r->minute, r->sec);
  } else {
    snprintf(ts, sizeof(ts), "NOTIME_%06lu", (unsigned long)r->boot);
  }

  char geo[80];
  if (r->flags & BF_FIX) {
    snprintf(geo, sizeof(geo), "%.6f,%.6f,%.1f,%.2f,%.1f,%d,%.1f",
             r->lat_e7 / 1e7, r->lon_e7 / 1e7, r->alt_m, r->speed_kts,
             r->cog, (int)r->sats, r->hdop);
  } else {
    snprintf(geo, sizeof(geo), ",,,,,,");
  }

  char bat[48];
  if (r->flags & BF_BATT) {
    snprintf(bat, sizeof(bat), "%.1f,%.3f,%.1f", r->batt_pct, r->batt_v, r->charge_rate);
  } else {
    snprintf(bat, sizeof(bat), ",,");
  }

  snprintf(out, n, "%s,%s,%s,%d,%d,%lu",
           ts, geo, bat,
           (r->flags & BF_RTCLOW) ? 1 : 0,
           (r->flags & BF_FIX) ? 1 : 0,
           (unsigned long)r->boot);
}

// Push a record into the RTC-memory ring buffer (oldest evicted when full).
void bufPush(const BufRec* r) {
  bufRecs[bufHead] = *r;
  bufHead = (bufHead + 1) % BUF_CAP;
  if (bufCount < BUF_CAP) {
    bufCount++;
  } else {
    bufDropped++;  // overran capacity — oldest unsaved fix was overwritten
  }
}

// Write all buffered records (oldest first) into an open file, then clear.
void bufFlush(File* f) {
  if (bufCount == 0) return;
  uint16_t idx = (bufHead - bufCount + BUF_CAP) % BUF_CAP;
  char line[160];
  for (uint16_t i = 0; i < bufCount; i++) {
    formatRec(line, sizeof(line), &bufRecs[idx]);
    f->println(line);
    idx = (idx + 1) % BUF_CAP;
  }
  Serial.printf("[BUF] flushed %u buffered fix(es) to SD\n", (unsigned)bufCount);
  bufCount = 0;
  bufDropped = 0;
}

// SD.begin() with a few quick retries to ride out transient contact loss.
bool sdBeginRetry(int tries) {
  for (int i = 0; i < tries; i++) {
    if (sdReady) return true;
    sdReady = SD.begin(SD_CS_PIN);
    if (sdReady) return true;
    SD.end();
    delay(50);
  }
  return false;
}

// ============================================================
// Log to daily rotated file with Kalman-filtered position
// ============================================================

void logToSD(bool hasFix, double logLat, double logLon) {
  char timestamp[22];
  getTimestamp(timestamp, sizeof(timestamp), hasFix);

  if (!sdBegin()) {
    blinkLED(5, 50, 50);
    return;
  }

  buildLogFileName();

  bool isNew = !SD.exists(logFileName);
  File logFile = SD.open(logFileName, FILE_APPEND);
  if (!logFile) {
    Serial.printf("[SD] Failed to open %s\n", logFileName);
    blinkLED(5, 50, 50);
    sdEnd();
    return;
  }

  if (isNew) {
    logFile.println("datetime,lat,lon,alt_m,speed_kts,cog,satellites,hdop,battery_pct,battery_v,charge_rate,rtc_bat_low,fix,boot");
  }

  logFile.print(timestamp);
  logFile.print(",");
  if (hasFix) {
    logFile.print(logLat, 6);
    logFile.print(",");
    logFile.print(logLon, 6);
    logFile.print(",");
    logFile.print(GPS.altitude, 1);
    logFile.print(",");
    logFile.print(GPS.speed, 2);
    logFile.print(",");
    logFile.print(GPS.angle, 1);
    logFile.print(",");
    logFile.print((int)GPS.satellites);
    logFile.print(",");
    logFile.print(GPS.HDOP, 1);
  } else {
    logFile.print(",,,,,,");
  }
  logFile.print(",");
  if (batteryOK) {
    logFile.print(battery.cellPercent(), 1);
    logFile.print(",");
    logFile.print(battery.cellVoltage(), 3);
    logFile.print(",");
    logFile.print(battery.chargeRate(), 1);
  } else {
    logFile.print(",,");
  }
  logFile.print(",");
  logFile.print(rtcBatteryLow ? "1" : "0");
  logFile.print(",");
  logFile.print(hasFix ? "1" : "0");
  logFile.print(",");
  logFile.println(bootCount);
  logFile.flush();
  logFile.close();
  sdEnd();
}

// ============================================================
// GPS cycle — simplified warm start, Kalman filter
// ============================================================

void doGPSCycle() {
  Serial.println("\n[CYCLE] === GPS Cycle Start ===");

  if (rtcOK) {
    DateTime now = rtc.now();
    Serial.printf("[RTC] %04d-%02d-%02d %02d:%02d:%02d\n",
                  now.year(), now.month(), now.day(),
                  now.hour(), now.minute(), now.second());
  }

  // Power on GPS — VBACKUP on FeatherWing retains ephemeris
  // so this is always a warm start unless battery was disconnected
  pinMode(GPS_ENABLE_PIN, OUTPUT);
  digitalWrite(GPS_ENABLE_PIN, HIGH);
  delay(200);

  Serial1.begin(9600, SERIAL_8N1, 38, -1);
  GPS.begin(9600);
  GPS.sendCommand(PMTK_SET_NMEA_OUTPUT_RMCGGA);
  GPS.sendCommand(PMTK_SET_NMEA_UPDATE_1HZ);
  delay(100);

  // Use cold timeout only on very first boot (no Kalman state = never had a fix)
  uint32_t timeout = kf_initialized ? GPS_TIMEOUT_WARM_MS : GPS_TIMEOUT_COLD_MS;

  bool hasFix = waitForFix(timeout);

  if (hasFix && rtcOK) {
    rtc.adjust(DateTime(
      GPS.year + 2000, GPS.month, GPS.day,
      GPS.hour, GPS.minute, GPS.seconds));
  }

  // Kalman filter processing
  double logLat = 0, logLon = 0;

  if (hasFix) {
    // Calculate dt since last fix for Kalman prediction
    uint32_t now_ms = millis();
    float dt = 0;
    if (kf_lastFixTime > 0 && kf_initialized) {
      // Estimate real elapsed time including sleep
      // Use RTC timestamps if available for accurate dt across deep sleep
      dt = (float)getSleepSeconds() + (now_ms / 1000.0);  // approximate
    }

    // Predict step (move state forward by dt)
    if (dt > 0) {
      kalmanPredict(dt);
    }

    // Update step (incorporate GPS measurement)
    kalmanUpdate(GPS.latitudeDegrees, GPS.longitudeDegrees, GPS.HDOP);
    kf_lastFixTime = now_ms;

    // Use filtered position for logging
    logLat = kf_lat;
    logLon = kf_lon;

    Serial.printf("[KF] raw=%.6f,%.6f → filtered=%.6f,%.6f\n",
                  GPS.latitudeDegrees, GPS.longitudeDegrees, logLat, logLon);
  }

  bool wasNoFix = (noFixCount > 0);

  if (hasFix) {
    lastSpeed = GPS.speed;

    if (GPS.speed > SPEED_THRESHOLD) {
      noFixCount = 0;
    } else {
      if (noFixCount > 0) noFixCount--;
    }

    updateMovementState(GPS.speed, wasNoFix);

    bool lowBat = (batteryOK && battery.cellVoltage() < LOW_BATTERY_V);
    blinkLED(lowBat ? 3 : 1, 100, 100);

    Serial.printf("[CYCLE] FIX: %.6f,%.6f spd=%.1f cog=%.1f sats=%d hdop=%.1f\n",
                  logLat, logLon, GPS.speed, GPS.angle, GPS.satellites, GPS.HDOP);

  } else {
    lastSpeed = 0;
    if (noFixCount < 255) noFixCount++;
    movingCount = 0;
    isMoving = false;
    blinkLED(2, 100, 100);
    Serial.printf("[CYCLE] NO FIX — noFixCount=%d\n", noFixCount);
  }

  logToSD(hasFix, logLat, logLon);

  // Power off GPS — VBACKUP keeps ephemeris alive during sleep
  digitalWrite(GPS_ENABLE_PIN, LOW);

  Serial.println("[CYCLE] === GPS Cycle End ===\n");
}

// ============================================================
// Web server handlers
// ============================================================

void handleRoot() {
  String html = "<!DOCTYPE html><html><head>";
  html += "<meta name='viewport' content='width=device-width, initial-scale=1'>";
  html += "<style>";
  html += "body{font-family:sans-serif;max-width:600px;margin:20px auto;padding:0 20px;background:#1a1a2e;color:#eee;}";
  html += "h1{color:#e94560;}";
  html += "a.btn{display:inline-block;margin:5px 3px;padding:10px 20px;background:#e94560;color:white;text-decoration:none;border-radius:8px;font-size:16px;}";
  html += "a.btn:hover{background:#c73450;}";
  html += "a.del{background:#555;font-size:13px;padding:8px 14px;}a.del:hover{background:#900;}";
  html += ".info{background:#16213e;padding:15px;border-radius:8px;margin:15px 0;}";
  html += ".warn{background:#3e2e16;padding:10px;border-radius:8px;margin:10px 0;color:#ffaa44;}";
  html += ".err{background:#3e1616;padding:10px;border-radius:8px;margin:10px 0;color:#ff4444;}";
  html += ".file{background:#16213e;padding:10px 15px;border-radius:8px;margin:6px 0;display:flex;justify-content:space-between;align-items:center;}";
  html += ".file .name{font-size:14px;font-family:monospace;}";
  html += ".file .size{font-size:12px;color:#888;}";
  html += ".file .actions{display:flex;gap:6px;}";
  html += ".stat{display:flex;justify-content:space-between;padding:4px 0;}";
  html += ".stat .label{color:#888;}";
  html += "</style></head><body>";
  html += "<h1>GPS Logger</h1>";

  html += "<div class='info'>";

  if (batteryOK) {
    float v = battery.cellVoltage();
    float pct = battery.cellPercent();
    float rate = battery.chargeRate();
    html += "<div class='stat'><span class='label'>Main battery</span><span>";
    html += String(pct, 1) + "% (" + String(v, 3) + "V)";
    if (v < LOW_BATTERY_V) html += " <b style='color:#e94560'>LOW</b>";
    if (rate > 0.5) {
      html += " <span style='color:#44ff44'>charging " + String(rate, 1) + "%/hr</span>";
    } else if (rate < -0.5) {
      html += " <span style='color:#ffaa44'>discharging " + String(-rate, 1) + "%/hr</span>";
    }
    html += "</span></div>";
  }

  if (rtcOK) {
    html += "<div class='stat'><span class='label'>RTC coin cell</span><span>";
    if (rtcBatteryLow) {
      html += "<b style='color:#e94560'>LOW — replace CR1220</b>";
    } else {
      html += "<span style='color:#44ff44'>OK</span>";
    }
    html += "</span></div>";

    DateTime now = rtc.now();
    char buf[22];
    snprintf(buf, sizeof(buf), "%04d-%02d-%02d %02d:%02d:%02d",
             now.year(), now.month(), now.day(),
             now.hour(), now.minute(), now.second());
    html += "<div class='stat'><span class='label'>Time (UTC)</span><span>" + String(buf) + "</span></div>";
  }

  html += "<div class='stat'><span class='label'>Boot count</span><span>" + String(bootCount) + "</span></div>";
  html += "<div class='stat'><span class='label'>Sleep interval</span><span>" + String(getSleepSeconds()) + "s</span></div>";
  html += "<div class='stat'><span class='label'>Kalman filter</span><span>" + String(kf_initialized ? "active" : "waiting for fix") + "</span></div>";

  if (avgFixTimeMs > 0) {
    html += "<div class='stat'><span class='label'>Avg fix time</span><span>" + String(avgFixTimeMs / 1000.0, 1) + "s</span></div>";
  }

  if (noFixCount > 0) {
    html += "<div class='stat'><span class='label'>No-fix streak</span><span>" + String(noFixCount) + "</span></div>";
  }

  html += "<div class='stat'><span class='label'>State</span><span>" + String(isMoving ? "moving" : "stationary") + "</span></div>";
  html += "</div>";

  if (rtcBatteryLow) {
    html += "<div class='err'>RTC coin cell battery is low. Replace the CR1220 to maintain timekeeping during power loss.</div>";
  }

  html += "<div class='warn'>WiFi shuts off after 2 min with no client (5 min if connected).</div>";

  if (sdBegin()) {
    File root = SD.open("/");
    if (root) {
      String files[200];
      unsigned long sizes[200];
      int fileCount = 0;

      File entry;
      while ((entry = root.openNextFile()) && fileCount < 200) {
        const char* name = entry.name();
        const char* p = name;
        if (*p == '/') p++;
        if (strncmp(p, "LOG_", 4) == 0) {
          files[fileCount] = String(p);
          sizes[fileCount] = entry.size();
          fileCount++;
        }
        entry.close();
      }
      root.close();

      // String sort works correctly with padded sequence numbers
      for (int i = 0; i < fileCount - 1; i++) {
        for (int j = i + 1; j < fileCount; j++) {
          if (files[i] > files[j]) {
            String tmpF = files[i];
            files[i] = files[j];
            files[j] = tmpF;
            unsigned long tmpS = sizes[i];
            sizes[i] = sizes[j];
            sizes[j] = tmpS;
          }
        }
      }

      unsigned long totalSize = 0;
      for (int i = 0; i < fileCount; i++) totalSize += sizes[i];

      html += "<h2 style='font-size:16px;color:#ccc;margin-top:20px;'>Log files (" + String(fileCount) + ", " + String(totalSize / 1024) + " KB total)</h2>";

      if (fileCount > 0) {
        html += "<div style='margin:10px 0;'>";
        html += "<a class='btn' href='/download_all'>Download All</a>";
        html += "<a class='del btn' href='/delete_all' onclick=\"return confirm('Delete ALL log files?')\">Delete All</a>";
        html += "</div>";
      }

      for (int i = fileCount - 1; i >= 0; i--) {
        html += "<div class='file'>";
        html += "<div><div class='name'>" + files[i] + "</div>";
        html += "<div class='size'>" + String(sizes[i] / 1024) + " KB</div></div>";
        html += "<div class='actions'>";
        html += "<a class='btn' href='/download?f=" + files[i] + "'>Download</a>";
        html += "<a class='del btn' href='/delete?f=" + files[i] + "' onclick=\"return confirm('Delete " + files[i] + "?')\">Delete</a>";
        html += "</div></div>";
      }

      if (fileCount == 0) {
        html += "<p>No log files yet.</p>";
      }
    } else {
      html += "<p>SD card error!</p>";
    }
    sdEnd();
  } else {
    html += "<p>SD card error!</p>";
  }

  html += "</body></html>";
  server.send(200, "text/html", html);
}

void handleDownload() {
  if (!server.hasArg("f")) {
    server.send(400, "text/plain", "Missing filename");
    return;
  }

  String filename = "/" + server.arg("f");

  if (!sdBegin()) {
    server.send(500, "text/plain", "SD card failed");
    return;
  }

  File logFile = SD.open(filename);
  if (!logFile) {
    server.send(404, "text/plain", "File not found");
    sdEnd();
    return;
  }

  server.sendHeader("Content-Disposition", "attachment; filename=" + server.arg("f"));
  server.sendHeader("Content-Length", String(logFile.size()));
  server.streamFile(logFile, "text/csv");
  logFile.close();
  sdEnd();
}

void handleDelete() {
  if (!server.hasArg("f")) {
    server.send(400, "text/plain", "Missing filename");
    return;
  }

  String filename = "/" + server.arg("f");

  if (sdBegin()) {
    SD.remove(filename.c_str());
    sdEnd();
  }

  server.sendHeader("Location", "/");
  server.send(303);
}

void handleDownloadAll() {
  if (!sdBegin()) {
    server.send(500, "text/plain", "SD card failed");
    return;
  }

  String files[200];
  int fileCount = 0;

  File root = SD.open("/");
  if (!root) {
    server.send(500, "text/plain", "Cannot open SD root");
    sdEnd();
    return;
  }

  File entry;
  while ((entry = root.openNextFile()) && fileCount < 200) {
    const char* name = entry.name();
    const char* p = name;
    if (*p == '/') p++;
    if (strncmp(p, "LOG_", 4) == 0) {
      files[fileCount] = String("/") + String(p);
      fileCount++;
    }
    entry.close();
  }
  root.close();

  if (fileCount == 0) {
    server.send(404, "text/plain", "No log files");
    sdEnd();
    return;
  }

  // String sort — works correctly with padded sequence numbers
  for (int i = 0; i < fileCount - 1; i++) {
    for (int j = i + 1; j < fileCount; j++) {
      if (files[i] > files[j]) {
        String tmp = files[i];
        files[i] = files[j];
        files[j] = tmp;
      }
    }
  }

  server.sendHeader("Content-Disposition", "attachment; filename=GPS_LOG_ALL.CSV");
  server.setContentLength(CONTENT_LENGTH_UNKNOWN);
  server.send(200, "text/csv", "");

  // Always use the new 14-column header regardless of individual file formats
  server.sendContent("datetime,lat,lon,alt_m,speed_kts,cog,satellites,hdop,battery_pct,battery_v,charge_rate,rtc_bat_low,fix,boot\n");

  for (int i = 0; i < fileCount; i++) {
    File f = SD.open(files[i]);
    if (!f) continue;

    bool firstLine = true;
    while (f.available()) {
      String line = f.readStringUntil('\n');
      if (firstLine) {
        firstLine = false;
        // Skip header line from every file
        continue;
      }
      if (line.length() > 5) {
        server.sendContent(line + "\n");
      }
    }
    f.close();
  }

  server.sendContent("");
  sdEnd();
}

void handleDeleteAll() {
  if (sdBegin()) {
    File root = SD.open("/");
    if (root) {
      String files[200];
      int count = 0;

      File entry;
      while ((entry = root.openNextFile()) && count < 200) {
        const char* name = entry.name();
        const char* p = name;
        if (*p == '/') p++;
        if (strncmp(p, "LOG_", 4) == 0) {
          files[count] = String("/") + String(p);
          count++;
        }
        entry.close();
      }
      root.close();

      for (int i = 0; i < count; i++) {
        SD.remove(files[i].c_str());
      }
    }
    sdEnd();
  }

  server.sendHeader("Location", "/");
  server.send(303);
}

// ============================================================
// WiFi server
// ============================================================

void runWiFiServer() {
  pinMode(GPS_ENABLE_PIN, OUTPUT);
  digitalWrite(GPS_ENABLE_PIN, LOW);

  blinkLED(3, 300, 300);

  WiFi.mode(WIFI_AP);
  WiFi.softAP(AP_SSID, AP_PASS);
  delay(1000);

  Serial.printf("WiFi: %s / %s\n", AP_SSID, AP_PASS);
  Serial.print("Browse: http://");
  Serial.println(WiFi.softAPIP());

  server.on("/", handleRoot);
  server.on("/download", handleDownload);
  server.on("/download_all", handleDownloadAll);
  server.on("/delete", handleDelete);
  server.on("/delete_all", handleDeleteAll);
  server.begin();

  unsigned long start = millis();
  unsigned long lastActivity = millis();

  while (true) {
    server.handleClient();

    bool hasClient = (WiFi.softAPgetStationNum() > 0);

    if (hasClient) lastActivity = millis();

    unsigned long timeout = hasClient ? WIFI_TIMEOUT_WITH_CLIENT : WIFI_TIMEOUT_NO_CLIENT;
    unsigned long since = hasClient ? start : lastActivity;

    if (millis() - since > timeout) break;

    static unsigned long lastBlink = 0;
    if (millis() - lastBlink > 2000) {
      lastBlink = millis();
      blinkLED(1, 50, 0);
    }
    delay(10);
  }

  Serial.println("WiFi timeout - shutting down");
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_OFF);

  blinkLED(3, 100, 100);
}

// ============================================================
// Setup
// ============================================================

void setup() {
  bootCount++;
  pinMode(STATUS_LED, OUTPUT);
  digitalWrite(STATUS_LED, LOW);

  bool freshReset = (sleepMagic != SLEEP_MAGIC);

  if (freshReset) {
    delay(3000);
  }

  Serial.begin(115200);
  if (freshReset) delay(500);

  Serial.printf("\n========== BOOT #%lu (%s) ==========\n",
                bootCount, freshReset ? "FRESH" : "SLEEP");

  Wire.begin();
  batteryOK = battery.begin();
  rtcOK = rtc.begin();
  delay(100);

  rtcBatteryLow = readRTCBatteryLow();

  if (batteryOK) {
    Serial.printf("[BAT] %.1f%% %.3fV rate=%.1f%%/hr\n",
                  battery.cellPercent(), battery.cellVoltage(), battery.chargeRate());
  }
  if (rtcOK) {
    Serial.printf("[RTC] OK, coin cell: %s\n", rtcBatteryLow ? "LOW" : "OK");
  }

  // Scan SD, migrate old filenames, find highest sequence
  logFileSeq = scanHighestSeqAndMigrate();

  if (freshReset) {
    logFileSeq++;
    noFixCount = 0;
    movingCount = 0;
    isMoving = false;
    avgFixTimeMs = 0;

    Serial.println("=== GPS Logger — WiFi Download Mode ===");
    Serial.printf("Log sequence: %lu\n", logFileSeq);

    runWiFiServer();
  } else if (Serial) {
    // USB connected during normal wake — start WiFi automatically
    // Just plug in USB cable and wait for next wake cycle
    Serial.println("[USB] USB detected — starting WiFi");
    runWiFiServer();
  }

  doGPSCycle();

  sleepMagic = SLEEP_MAGIC;

  int sleepTime = getSleepSeconds();
  Serial.printf("[SLEEP] %ds | noFix=%d | %s | KF=%s\n",
                sleepTime, noFixCount, isMoving ? "moving" : "stationary",
                kf_initialized ? "active" : "init");
  Serial.flush();

  esp_sleep_enable_timer_wakeup((uint64_t)sleepTime * 1000000ULL);
  esp_deep_sleep_start();
}

void loop() {}

