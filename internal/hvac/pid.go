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
