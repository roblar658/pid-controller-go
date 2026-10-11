# HVAC Controller & Termisk Simulering

PID-basert reguleringssystem for ventilasjon og inneklima i Go, simulert med Newtons avkjølings- og oppvarmingslov og visualisert med et interaktivt web-dashbord (Chart.js).

---

## Egenskaper

- **PID-kontroller (`internal/hvac/pid.go`):** Regulerer temperatur med proporsjonal-, integral- og derivatvirkning, inkludert anti-windup (integratorklemming) og utgangsmetning (0–100%).
- **Fysisk modell (`internal/hvac/thermal.go`):** Romdynamikk modellert med Newtons avkjølings- og oppvarmingslov mot uteluft og tvungen konveksjon via ventilasjonsluft.
- **Maskinvareabstraksjon (`internal/hvac/ventilation.go`):** Grensesnitt (`TemperatureSensor`, `VentilationActuator`) som gjør det enkelt å koble opp fysiske sensorer og aktuatorer.
- **Web-dashbord (`cmd/server/main.go`):** Innebygd HTTP-server som plotter temperatur (PV), settpunkt (SP) og viftepådrag (MV) over tid.

---

## Forutsetninger

- **Go 1.22+** installert og lagt til i `PATH`.

---

## How to Run

### 1. Start simulatoren og webserveren

Kjør følgende kommando fra rotmappen (`hvac-controller`):

```bash
go run ./cmd/server
<img width="918" height="482" alt="image" src="https://github.com/user-attachments/assets/a909b8b8-4be2-4c29-9845-5387e4ef7086" />
