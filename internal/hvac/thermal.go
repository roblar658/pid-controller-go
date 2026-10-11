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
