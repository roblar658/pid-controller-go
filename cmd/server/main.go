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
