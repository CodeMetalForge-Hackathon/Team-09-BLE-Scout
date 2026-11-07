// Wildfire SAR sensor pod: flame (D2), temp (A0), moisture (A1)

const int   FLAME_PIN  = 2;
const int   TEMP_PIN   = A0;
const int   MOIST_PIN  = A1;
const int   B          = 4275;
const float R0         = 100000.0;
const float CAL_OFFSET = -55.5;

void setup() {
  Serial.begin(9600);
  pinMode(FLAME_PIN, INPUT_PULLUP);
}

void loop() {
  int raw = analogRead(TEMP_PIN);
  float R = R0 * (1023.0 / raw - 1.0);
  float tempC = 1.0 / (log(R / R0) / B + 1 / 298.15) - 273.15;
  float tempF = tempC * 9.0 / 5.0 + 32.0 + CAL_OFFSET;
  bool flame = digitalRead(FLAME_PIN) == LOW;
  int moisture = analogRead(MOIST_PIN);

  Serial.print("Temp: ");
  Serial.print(tempF, 1);
  Serial.print(" F | Moisture: ");
  Serial.print(moisture);
  Serial.print(" | ");
  Serial.println(flame ? "FLAME!" : "no flame");
  delay(500);
}