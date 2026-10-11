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
