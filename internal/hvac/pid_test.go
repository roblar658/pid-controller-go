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
