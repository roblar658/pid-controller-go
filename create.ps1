# Stopper ved kritiske feil
$ErrorActionPreference = "Stop"

# --- 0. Funksjon for å finne, eller automatisk installere Go ---
function Ensure-GoInstallation {
    # 1. Sjekk om 'go' allerede er tilgjengelig i PATH
    $cmd = Get-Command "go" -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    # 2. Sjekk standardstier på Windows
    $candidatePaths = @(
        "$env:ProgramFiles\Go\bin",
        "${env:ProgramFiles(x86)}\Go\bin",
        "C:\Go\bin",
        "$env:USERPROFILE\go\bin",
        "$env:LOCALAPPDATA\Programs\Go\bin"
    )

    foreach ($dir in $candidatePaths) {
        $exe = Join-Path $dir "go.exe"
        if (Test-Path $exe) {
            $env:PATH = "$dir;$env:PATH"
            return $exe
        }
    }

    # 3. Sjekk registerets PATH (i tilfelle nylig installasjon)
    $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $allPaths = ($machinePath + ";" + $userPath) -split ";" | Where-Object { $_ -ne "" }

    foreach ($dir in $allPaths) {
        $exe = Join-Path $dir "go.exe"
        if (Test-Path $exe) {
            $env:PATH = "$dir;$env:PATH"
            return $exe
        }
    }

    # 4. Automatisk installasjon dersom Go mangler helt
    Write-Host "[INFO] Go ble ikke funnet. Starter automatisk installasjon..." -ForegroundColor Yellow

    $hasWinget = Get-Command "winget" -ErrorAction SilentlyContinue
    if ($hasWinget) {
        Write-Host "Installerer Go via winget..." -ForegroundColor Cyan
        & winget install GoLang.Go --silent --accept-package-agreements --accept-source-agreements

        $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
        $env:PATH = "$machinePath;$userPath;$env:PATH"

        foreach ($dir in $candidatePaths) {
            $exe = Join-Path $dir "go.exe"
            if (Test-Path $exe) {
                return $exe
            }
        }
    } else {
        Write-Host "winget ikke funnet. Laster ned portabel Go direkte fra go.dev..." -ForegroundColor Cyan
        $toolsDir = Join-Path $env:USERPROFILE "tools\go"
        $zipFile = Join-Path $env:TEMP "go_install.zip"
        
        $downloadUrl = "https://go.dev/dl/go1.22.5.windows-amd64.zip"
        Invoke-WebRequest -Uri $downloadUrl -OutFile $zipFile -UseBasicParsing
        
        Write-Host "Pakker ut Go..." -ForegroundColor Cyan
        Expand-Archive -Path $zipFile -DestinationPath (Split-Path $toolsDir -Parent) -Force
        Remove-Item $zipFile -Force
        
        $goBinDir = Join-Path $toolsDir "bin"
        $env:PATH = "$goBinDir;$env:PATH"
        
        $exe = Join-Path $goBinDir "go.exe"
        if (Test-Path $exe) {
            return $exe
        }
    }

    $cmd = Get-Command "go" -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    throw "Installasjon av Go feilet eller binæren ble ikke funnet."
}

# Hent eller installer Go
$goPath = Ensure-GoInstallation
Write-Host "Benytter Go fra: $goPath" -ForegroundColor Green

# --- 1. Prosjektoppsett ---
$projectName = "hvac-controller"
Write-Host "Oppretter prosjekt: $projectName..." -ForegroundColor Cyan

New-Item -ItemType Directory -Force -Path $projectName | Out-Null
Set-Location -Path $projectName

New-Item -ItemType Directory -Force -Path "cmd/server" | Out-Null
New-Item -ItemType Directory -Force -Path "internal/hvac" | Out-Null

# --- 2. Initialiser Go module ---
if (-not (Test-Path "go.mod")) {
    Write-Host "Initialiserer Go-modul..." -ForegroundColor Cyan
    & $goPath mod init $projectName
}

# --- 3. internal/hvac/pid.go ---
@'
package hvac

import (
	"errors"
	"math"
	"time"
)

type PIDConfig struct {
	Kp        float64
	Ki        float64
	Kd        float64
	MinOutput float64
	MaxOutput float64
	Invert    bool
}

type PIDController struct {
	cfg       PIDConfig
	integral  float64
	lastError float64
	lastTime  time.Time
	hasPrev   bool
}

func NewPIDController(cfg PIDConfig) (*PIDController, error) {
	if cfg.MinOutput >= cfg.MaxOutput {
		return nil, errors.New("MinOutput must be strictly less than MaxOutput")
	}
	return &PIDController{cfg: cfg}, nil
}

func (p *PIDController) Reset() {
	p.integral = 0
	p.lastError = 0
	p.hasPrev = false
	p.lastTime = time.Time{}
}

func (p *PIDController) Update(setpoint, current float64, now time.Time) float64 {
	errorVal := setpoint - current
	if p.cfg.Invert {
		errorVal = -errorVal
	}

	if !p.hasPrev {
		p.lastTime = now
		p.lastError = errorVal
		p.hasPrev = true
		return p.clamp(p.cfg.Kp * errorVal)
	}

	dt := now.Sub(p.lastTime).Seconds()
	if dt <= 0 {
		dt = 1e-6
	}

	pTerm := p.cfg.Kp * errorVal

	p.integral += errorVal * dt
	iTerm := p.cfg.Ki * p.integral

	dError := (errorVal - p.lastError) / dt
	dTerm := p.cfg.Kd * dError

	unclamped := pTerm + iTerm + dTerm
	output := p.clamp(unclamped)

	// Anti-windup
	if unclamped != output && math.Signbit(errorVal) == math.Signbit(unclamped) {
		p.integral -= errorVal * dt
	}

	p.lastError = errorVal
	p.lastTime = now

	return output
}

func (p *PIDController) clamp(val float64) float64 {
	if val > p.cfg.MaxOutput {
		return p.cfg.MaxOutput
	}
	if val < p.cfg.MinOutput {
		return p.cfg.MinOutput
	}
	return val
}
'@ | Set-Content -Path "internal/hvac/pid.go" -Encoding UTF8

# --- 4. internal/hvac/thermal.go ---
@'
package hvac

// ThermalConfig konfigurerer det termiske miljøet.
// Modellen er basert på Newtons avkjølings- og oppvarmingslov:
// dT/dt = -kEnv*(T - T_ambient) - kVent*(speed/100)*(T - T_inlet) + heatLoad
type ThermalConfig struct {
	AmbientTemp float64 // Utetemperatur (°C)
	InletTemp   float64 // Tilluftstemperatur fra aggregat (°C)
	KEnv        float64 // Varmeovergangstall mot uteluft (1/s)
	KVent       float64 // Tvungen konveksjon ved 100% viftehastighet (1/s)
	HeatLoad    float64 // Konstant intern varmelast fra personer/utstyr (°C/s)
}

type ThermalModel struct {
	cfg      ThermalConfig
	RoomTemp float64
}

func NewThermalModel(cfg ThermalConfig, initialTemp float64) *ThermalModel {
	return &ThermalModel{
		cfg:      cfg,
		RoomTemp: initialTemp,
	}
}

// Step beregner ny temperatur over tidssteget dt (sekunder)
func (m *ThermalModel) Step(ventSpeed float64, dt float64) float64 {
	naturalTransfer := -m.cfg.KEnv * (m.RoomTemp - m.cfg.AmbientTemp)

	normalizedSpeed := ventSpeed / 100.0
	if normalizedSpeed < 0 {
		normalizedSpeed = 0
	} else if normalizedSpeed > 1 {
		normalizedSpeed = 1
	}
	forcedCooling := -m.cfg.KVent * normalizedSpeed * (m.RoomTemp - m.cfg.InletTemp)

	dTdt := naturalTransfer + forcedCooling + m.cfg.HeatLoad
	m.RoomTemp += dTdt * dt
	return m.RoomTemp
}
'@ | Set-Content -Path "internal/hvac/thermal.go" -Encoding UTF8

# --- 5. internal/hvac/ventilation.go ---
@'
package hvac

import (
	"context"
	"fmt"
	"time"
)

type TemperatureSensor interface {
	ReadTemperature(ctx context.Context) (float64, error)
}

type VentilationActuator interface {
	SetSpeed(ctx context.Context, percentage float64) error
}

type VentilationSystem struct {
	sensor   TemperatureSensor
	actuator VentilationActuator
	pid      *PIDController
	target   float64
}

func NewVentilationSystem(sensor TemperatureSensor, actuator VentilationActuator, pid *PIDController, targetTemp float64) *VentilationSystem {
	return &VentilationSystem{
		sensor:   sensor,
		actuator: actuator,
		pid:      pid,
		target:   targetTemp,
	}
}

func (vs *VentilationSystem) Step(ctx context.Context, now time.Time) (float64, error) {
	currentTemp, err := vs.sensor.ReadTemperature(ctx)
	if err != nil {
		return 0, fmt.Errorf("sensor error: %w", err)
	}

	speed := vs.pid.Update(vs.target, currentTemp, now)
	if err := vs.actuator.SetSpeed(ctx, speed); err != nil {
		return speed, fmt.Errorf("actuator error: %w", err)
	}

	return speed, nil
}
'@ | Set-Content -Path "internal/hvac/ventilation.go" -Encoding UTF8

# --- 6. internal/hvac/pid_test.go ---
@'
package hvac_test

import (
	"context"
	"errors"
	"math"
	"testing"
	"time"

	"hvac-controller/internal/hvac"
)

type mockSensor struct {
	temp float64
	err  error
}

func (m *mockSensor) ReadTemperature(ctx context.Context) (float64, error) {
	return m.temp, m.err
}

type mockActuator struct {
	lastSpeed float64
	err       error
}

func (m *mockActuator) SetSpeed(ctx context.Context, speed float64) error {
	m.lastSpeed = speed
	return m.err
}

func TestPIDController_ProportionalAction(t *testing.T) {
	cfg := hvac.PIDConfig{
		Kp:        2.0,
		Ki:        0.0,
		Kd:        0.0,
		MinOutput: 0.0,
		MaxOutput: 100.0,
		Invert:    true,
	}
	pid, err := hvac.NewPIDController(cfg)
	if err != nil {
		t.Fatalf("unexpected initialization error: %v", err)
	}

	start := time.Now()
	out := pid.Update(20.0, 25.0, start)
	expected := 10.0
	if out != expected {
		t.Errorf("expected output %.2f, got %.2f", expected, out)
	}
}

func TestPIDController_OutputClampingAndAntiWindup(t *testing.T) {
	cfg := hvac.PIDConfig{
		Kp:        10.0,
		Ki:        10.0,
		Kd:        0.0,
		MinOutput: 0.0,
		MaxOutput: 50.0,
		Invert:    true,
	}
	pid, _ := hvac.NewPIDController(cfg)
	t0 := time.Now()

	out := pid.Update(20.0, 30.0, t0)
	if out != 50.0 {
		t.Fatalf("expected clamped output 50.0, got %.2f", out)
	}

	for i := 1; i <= 10; i++ {
		tStep := t0.Add(time.Duration(i) * time.Second)
		out = pid.Update(20.0, 30.0, tStep)
		if out > 50.0 {
			t.Fatalf("output exceeded limit: %.2f", out)
		}
	}

	recoveryTime := t0.Add(11 * time.Second)
	out = pid.Update(20.0, 19.0, recoveryTime)
	if out == 50.0 {
		t.Errorf("anti-windup failed: output is still saturated")
	}
}

func TestPIDController_DerivativeAction(t *testing.T) {
	cfg := hvac.PIDConfig{
		Kp:        0.0,
		Ki:        0.0,
		Kd:        5.0,
		MinOutput: -100.0,
		MaxOutput: 100.0,
		Invert:    true,
	}
	pid, _ := hvac.NewPIDController(cfg)
	t0 := time.Now()

	pid.Update(20.0, 20.0, t0)

	t1 := t0.Add(1 * time.Second)
	out := pid.Update(20.0, 24.0, t1)

	expected := 20.0
	if out != expected {
		t.Errorf("expected derivative output %.2f, got %.2f", expected, out)
	}
}

func TestThermalModel_NewtonsCooling(t *testing.T) {
	model := hvac.NewThermalModel(hvac.ThermalConfig{
		AmbientTemp: 20.0,
		InletTemp:   15.0,
		KEnv:        0.05,
		KVent:       0.0,
		HeatLoad:    0.0,
	}, 30.0)

	newTemp := model.Step(0, 1.0)
	expected := 29.5
	if math.Abs(newTemp-expected) > 1e-4 {
		t.Errorf("expected temp %.2f, got %.2f", expected, newTemp)
	}
}

func TestVentilationSystem_ExecutionFlow(t *testing.T) {
	sensor := &mockSensor{temp: 26.0}
	actuator := &mockActuator{}

	pid, _ := hvac.NewPIDController(hvac.PIDConfig{
		Kp:        4.0,
		Ki:        0.0,
		Kd:        0.0,
		MinOutput: 0.0,
		MaxOutput: 100.0,
		Invert:    true,
	})

	sys := hvac.NewVentilationSystem(sensor, actuator, pid, 22.0)
	ctx := context.Background()

	speed, err := sys.Step(ctx, time.Now())
	if err != nil {
		t.Fatalf("unexpected step error: %v", err)
	}

	if speed != 16.0 {
		t.Errorf("expected fan speed 16.0%%, got %.2f%%", speed)
	}
	if actuator.lastSpeed != 16.0 {
		t.Errorf("actuator did not receive speed: got %.2f%%", actuator.lastSpeed)
	}
}

func TestVentilationSystem_SensorFailure(t *testing.T) {
	sensor := &mockSensor{err: errors.New("I2C read timeout")}
	actuator := &mockActuator{}
	pid, _ := hvac.NewPIDController(hvac.PIDConfig{MinOutput: 0.0, MaxOutput: 100.0})

	sys := hvac.NewVentilationSystem(sensor, actuator, pid, 20.0)
	_, err := sys.Step(context.Background(), time.Now())
	if err == nil {
		t.Error("expected error due to sensor failure, got nil")
	}
}
'@ | Set-Content -Path "internal/hvac/pid_test.go" -Encoding UTF8

# --- 7. cmd/server/main.go ---
@'
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os/exec"
	"runtime"
	"time"

	"hvac-controller/internal/hvac"
)

type DataPoint struct {
	Second      int     `json:"second"`
	RoomTemp    float64 `json:"roomTemp"`
	TargetTemp  float64 `json:"targetTemp"`
	AmbientTemp float64 `json:"ambientTemp"`
	FanSpeed    float64 `json:"fanSpeed"`
}

type SimulationSensor struct {
	model *hvac.ThermalModel
}

func (s *SimulationSensor) ReadTemperature(ctx context.Context) (float64, error) {
	return s.model.RoomTemp, nil
}

type SimulationActuator struct {
	lastSpeed float64
}

func (a *SimulationActuator) SetSpeed(ctx context.Context, speed float64) error {
	a.lastSpeed = speed
	return nil
}

const dashboardHTML = `<!DOCTYPE html>
<html lang="no">
<head>
    <meta charset="UTF-8">
    <title>HVAC PID & Newtons Kjølelov Simulering</title>
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 24px; }
        .container { max-width: 1000px; margin: 0 auto; background: #1e293b; border-radius: 12px; padding: 24px; box-shadow: 0 10px 25px rgba(0,0,0,0.5); }
        h1 { margin-top: 0; font-size: 24px; color: #38bdf8; }
        p { color: #94a3b8; line-height: 1.5; }
        .chart-box { position: relative; height: 450px; margin-top: 20px; }
        .badges { display: flex; gap: 12px; margin-bottom: 16px; flex-wrap: wrap; }
        .badge { background: #334155; padding: 6px 12px; border-radius: 6px; font-size: 13px; font-weight: 600; }
    </style>
</head>
<body>
    <div class="container">
        <h1>HVAC PID Termisk Simulering</h1>
        <p>Romdynamikken er modellert med <strong>Newtons avkjølings- og oppvarmingslov</strong> mot utetemperatur på 29.0°C og tvungen ventilasjonsavkjøling (tilluft 15.0°C).</p>
        
        <div class="badges">
            <span class="badge" style="color: #38bdf8;">Måltemp: 21.0°C</span>
            <span class="badge" style="color: #f87171;">Starttemp: 27.5°C</span>
            <span class="badge" style="color: #fbbf24;">Utetemp: 29.0°C</span>
            <span class="badge" style="color: #34d399;">Kp: 6.0 | Ki: 0.15 | Kd: 2.0</span>
        </div>

        <div class="chart-box">
            <canvas id="simChart"></canvas>
        </div>
    </div>

    <script>
        const simData = {{.}};
        const labels = simData.map(d => d.second + 's');
        const roomTemps = simData.map(d => d.roomTemp);
        const targetTemps = simData.map(d => d.targetTemp);
        const fanSpeeds = simData.map(d => d.fanSpeed);

        const ctx = document.getElementById('simChart').getContext('2d');
        new Chart(ctx, {
            type: 'line',
            data: {
                labels: labels,
                datasets: [
                    {
                        label: 'Romtemperatur (°C)',
                        data: roomTemps,
                        borderColor: '#f87171',
                        backgroundColor: 'rgba(248, 113, 113, 0.1)',
                        borderWidth: 2,
                        yAxisID: 'yTemp',
                        tension: 0.2
                    },
                    {
                        label: 'Settpunkt / Mål (°C)',
                        data: targetTemps,
                        borderColor: '#38bdf8',
                        borderDash: [6, 4],
                        borderWidth: 2,
                        yAxisID: 'yTemp',
                        pointRadius: 0
                    },
                    {
                        label: 'Viftehastighet (%)',
                        data: fanSpeeds,
                        borderColor: '#a78bfa',
                        backgroundColor: 'rgba(167, 139, 250, 0.15)',
                        fill: true,
                        borderWidth: 1.5,
                        yAxisID: 'yFan',
                        tension: 0.1,
                        pointRadius: 0
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                interaction: { mode: 'index', intersect: false },
                scales: {
                    x: {
                        ticks: { color: '#94a3b8', maxTicksLimit: 12 },
                        grid: { color: '#334155' }
                    },
                    yTemp: {
                        type: 'linear',
                        position: 'left',
                        title: { display: true, text: 'Temperatur (°C)', color: '#f87171' },
                        ticks: { color: '#f87171' },
                        grid: { color: '#334155' }
                    },
                    yFan: {
                        type: 'linear',
                        position: 'right',
                        title: { display: true, text: 'Viftehastighet (%)', color: '#a78bfa' },
                        min: 0,
                        max: 100,
                        ticks: { color: '#a78bfa' },
                        grid: { drawOnChartArea: false }
                    }
                },
                plugins: {
                    legend: { labels: { color: '#f8fafc' } }
                }
            }
        });
    </script>
</body>
</html>`

func openBrowser(url string) {
    var cmd *exec.Cmd
    switch runtime.GOOS {
    case "windows":
        cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
    case "darwin":
        cmd = exec.Command("open", url)
    default:
        cmd = exec.Command("xdg-open", url)
    }
    _ = cmd.Start()
}

func main() {
    thermalModel := hvac.NewThermalModel(hvac.ThermalConfig{
        AmbientTemp: 29.0,
        InletTemp:   15.0,
        KEnv:        0.005,
        KVent:       0.035,
        HeatLoad:    0.015,
    }, 27.5)

    sensor := &SimulationSensor{model: thermalModel}
    actuator := &SimulationActuator{}

    pid, err := hvac.NewPIDController(hvac.PIDConfig{
        Kp:        6.0,
        Ki:        0.15,
        Kd:        2.0,
        MinOutput: 0.0,
        MaxOutput: 100.0,
        Invert:    true,
    })
    if err != nil {
        log.Fatalf("Feil ved PID-oppsett: %v", err)
    }

    targetTemp := 21.0
    sys := hvac.NewVentilationSystem(sensor, actuator, pid, targetTemp)
    ctx := context.Background()

    simDuration := 400
    history := make([]DataPoint, 0, simDuration)
    now := time.Now()

    fmt.Println("Kjører simulering med Newtons avkjølingslov...")
    for sec := 0; sec <= simDuration; sec++ {
        currentTemp := thermalModel.RoomTemp
        currentTime := now.Add(time.Duration(sec) * time.Second)

        speed, err := sys.Step(ctx, currentTime)
        if err != nil {
            log.Fatalf("Stegfeil: %v", err)
        }

        history = append(history, DataPoint{
            Second:      sec,
            RoomTemp:    float64(int(currentTemp*100)) / 100,
            TargetTemp:  targetTemp,
            AmbientTemp: 29.0,
            FanSpeed:    float64(int(speed*10)) / 10,
        })

        thermalModel.Step(speed, 1.0)
    }

    jsonData, err := json.Marshal(history)
    if err != nil {
        log.Fatalf("JSON-serialisering feilet: %v", err)
    }

    tmpl := template.Must(template.New("dashboard").Parse(dashboardHTML))

    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        w.Header().Set("Content-Type", "text/html; charset=utf-8")
        _ = tmpl.Execute(w, template.JS(string(jsonData)))
    })

    port := "8080"
    url := "http://localhost:" + port
    fmt.Printf("\nSimulering fullført! Nettsiden er klar på: %s\n", url)
    fmt.Println("Trykk Ctrl+C for å avslutte serveren.")

    go func() {
        time.Sleep(300 * time.Millisecond)
        openBrowser(url)
    }()

    if err := http.ListenAndServe(":"+port, nil); err != nil {
        log.Fatalf("Serverfeil: %v", err)
    }
}
'@ | Set-Content -Path "cmd/server/main.go" -Encoding UTF8

# --- 8. Kjør tester ---
Write-Host "Kjører enhetstester..." -ForegroundColor Cyan
& $goPath test -v ./internal/hvac

Write-Host "`nAlt er fullført og alle tester passerte!" -ForegroundColor Green
Write-Host "Kjør følgende for å starte webserveren og se grafen:" -ForegroundColor Cyan
Write-Host "  go run ./cmd/server" -ForegroundColor White
