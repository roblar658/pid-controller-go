# HVAC Controller & Termisk Simulering

PID-basert reguleringssystem for ventilasjon og inneklima i Go, simulert med Newtons avkjølings- og oppvarmingslov og visualisert med et interaktivt web-dashbord (Chart.js).

<img width="842" height="478" alt="image" src="https://github.com/user-attachments/assets/6172f32b-52e0-4f79-87c7-0c3d78168238" />


---

## Matematiske modeller og formler

### 1. Newtons avkjølings- og oppvarmingslov (`thermal.go`)
Rommets temperaturutvikling over tid modelleres som en førsteordens differensialligning med tre ledd: naturlig varmeovergang mot uteluft, tvungen konveksjonskjøling fra ventilasjonen og intern varmelast (personer, lys, utstyr):

$$\frac{dT}{dt} = -k_{\text{env}} (T - T_{\text{ambient}}) - k_{\text{vent}} \cdot \left(\frac{u}{100}\right) \cdot (T - T_{\text{inlet}}) + \dot{Q}_{\text{intern}}$$

* **$T$:** Nåværende romtemperatur (°C)
* **$T_{\text{ambient}}$:** Utetemperatur (°C)
* **$T_{\text{inlet}}$:** Tilluftstemperatur fra ventilasjonsaggregat (°C)
* **$u$:** Viftepådrag ($0 \le u \le 100\ \%$)
* **$k_{\text{env}}$:** Varmeovergangstall mot omgivelsene ($1/\text{s}$)
* **$k_{\text{vent}}$:** Varmeovergangstall for tvungen konveksjon ved full viftehastighet ($1/\text{s}$)
* **$\dot{Q}_{\text{intern}}$:** Konstant intern varmeeffekt (°C/s)

I simulatoren diskretiseres ligningen ved hjelp av Eulers metode med tidssteg $\Delta t$:

$$T_{k+1} = T_k + \frac{dT}{dt} \cdot \Delta t$$

---

### 2. PID-regulator med anti-windup (`pid.go`)

#### Avvik (Error)
Siden systemet styrer kjøling (høyere temperatur krever økt viftehastighet), er feilleddet invertert:

$$e(t) = -(T_{\text{sp}} - T(t)) = T(t) - T_{\text{sp}}$$

* **$T_{\text{sp}}$:** Settpunkt/måltemperatur
* **$T(t)$:** Målt romtemperatur

#### Kontrollerligning (kontinuerlig form)
$$u_{\text{unclamped}}(t) = K_p \, e(t) + K_i \int_0^t e(\tau) \, d\tau + K_d \, \frac{de(t)}{dt}$$

#### Diskret implementasjon (tidssteg $k$ med $\Delta t$)
* **P-ledd:** 
  $$P_k = K_p \cdot e_k$$
* **I-ledd:** 
  $$I_k = I_{k-1} + e_k \cdot \Delta t$$
  $$\text{Integralledd} = K_i \cdot I_k$$
* **D-ledd:** 
  $$D_k = K_d \cdot \frac{e_k - e_{k-1}}{\Delta t}$$

Total uavskåret utgang:
$$u_{\text{unclamped}} = P_k + K_i \cdot I_k + D_k$$

#### Metning og Anti-windup (Clamping)
Utgangen begrenses innenfor aktuatorminimum og -maksimum:

$$u_k = \max\left(u_{\min},\ \min\left(u_{\max},\ u_{\text{unclamped}}\right)\right)$$

Dersom pådraget er mettet ($u_{\text{unclamped}} \neq u_k$) og feilen $e_k$ har samme fortegn som pådraget, akkumuleres ikke integralfeilen videre (anti-windup back-calculation):

$$I_k \leftarrow I_k - e_k \cdot \Delta t$$

---

## Egenskaper

- **PID-kontroller (`internal/hvac/pid.go`):** Regulerer temperatur med proporsjonal-, integral- og derivatvirkning, inkludert anti-windup og utgangsmetning (0–100%).
- **Fysisk modell (`internal/hvac/thermal.go`):** Romdynamikk modellert med Newtons avkjølings- og oppvarmingslov mot uteluft og tvungen konveksjon via ventilasjonsluft.
- **Maskinvareabstraksjon (`internal/hvac/ventilation.go`):** Grensesnitt (`TemperatureSensor`, `VentilationActuator`) som gjør det enkelt å koble opp fysiske sensorer og aktuatorer.
- **Web-dashbord (`cmd/server/main.go`):** Innebygd HTTP-server som plotter temperatur ($PV$), settpunkt ($SP$) og viftepådrag ($MV$) over tid.

---

## Forutsetninger

- **Go 1.22+** installert og lagt til i `PATH`.

---

## How to Run

### 1. Start simulatoren og webserveren

Kjør følgende kommando fra rotmappen (`hvac-controller`):

```bash
go run ./cmd/server
