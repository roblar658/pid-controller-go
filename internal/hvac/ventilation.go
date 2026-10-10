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
