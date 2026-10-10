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
    $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
    $allPaths    = ($machinePath + ";" + $userPath) -split ";" | Where-Object { $_ -ne "" }

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
        Write-Host "Installerer Go via winget (aksepterer lisens og kildebetingelser)..." -ForegroundColor Cyan
        & winget install GoLang.Go --silent --accept-package-agreements --accept-source-agreements

        # Oppdater miljøvariabler fra registeret etter installasjon
        $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPath    = [System.Environment]::GetEnvironmentVariable("Path", "User")
        $env:PATH    = "$machinePath;$userPath;$env:PATH"

        foreach ($dir in $candidatePaths) {
            $exe = Join-Path $dir "go.exe"
            if (Test-Path $exe) {
                return $exe
            }
        }
    } else {
        # Fallback hvis winget ikke finnes: Last ned og pakk ut Go lokalt
        Write-Host "winget ikke funnet. Laster ned portabel Go direkte fra go.dev..." -ForegroundColor Cyan
        $toolsDir = Join-Path $env:USERPROFILE "tools\go"
        $zipFile  = Join-Path $env:TEMP "go_install.zip"
        
        # Henter nyeste stabile Go-versjon
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

    # Siste sjekk etter installasjonsforsøk
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

# --- 2. Initialiser Go module (hvis ikke allerede initialisert) ---
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

# --- 4. internal/hvac/ventilation.go ---
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

# --- 5. internal/hvac/pid_test.go ---
@'
package hvac_test

import (
	"context"
	"errors"
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

# --- 6. cmd/server/main.go ---
@'
package main

import (
	"context"
	"fmt"
	"log"
	"time"

	"hvac-controller/internal/hvac"
)

type DummySensor struct {
	temp float64
}

func (d *DummySensor) ReadTemperature(ctx context.Context) (float64, error) {
	return d.temp, nil
}

type ConsoleActuator struct{}

func (c *ConsoleActuator) SetSpeed(ctx context.Context, speed float64) error {
	fmt.Printf("[Aktuator] Vifte justert til: %.1f%%\n", speed)
	return nil
}

func main() {
	sensor := &DummySensor{temp: 24.5}
	actuator := &ConsoleActuator{}

	pid, err := hvac.NewPIDController(hvac.PIDConfig{
		Kp:        3.0,
		Ki:        0.1,
		Kd:        0.5,
		MinOutput: 0.0,
		MaxOutput: 100.0,
		Invert:    true,
	})
	if err != nil {
		log.Fatalf("Feil ved oppsett av PID: %v", err)
	}

	targetTemp := 21.0
	sys := hvac.NewVentilationSystem(sensor, actuator, pid, targetTemp)
	ctx := context.Background()

	fmt.Println("Starter HVAC regulering...")
	speed, err := sys.Step(ctx, time.Now())
	if err != nil {
		log.Fatalf("Reguleringsfeil: %v", err)
	}

	fmt.Printf("Målt: %.1f°C | Mål: %.1f°C -> Vifte: %.1f%%\n", sensor.temp, targetTemp, speed)
}
'@ | Set-Content -Path "cmd/server/main.go" -Encoding UTF8

# --- 7. Kjør tester ---
Write-Host "Kjører enhetstester..." -ForegroundColor Cyan
& $goPath test -v ./...

Write-Host "`nAlt er fullført og testene passerte!" -ForegroundColor Green
Write-Host "Kjør 'code .' for å åpne prosjektet i VS Code." -ForegroundColor Yellow
