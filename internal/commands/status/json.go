package status

import (
	"encoding/json"
	"fmt"
	"time"
)

type obj = map[string]any

func nz(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nk[T any](k Known[T]) any {
	if !k.OK {
		return nil
	}
	return k.V
}

func nf(p *float64) any {
	if p == nil {
		return nil
	}
	return *p
}

// JSON is `cg status --json`: the same facts as the report, as data. An
// unreadable fact is null - never 0 or false: "I could not look" is not "there
// is none". Keys sort.
func (v View) JSON() ([]byte, error) {
	f, r := v.Facts, v.Rates
	acct := obj{"id": f.AccountID, "plan": f.Plan, "credits": f.Credits}
	if f.AccountID == "" {
		acct["id"] = "NO CREDENTIALS"
	}
	out := obj{
		"host": v.Host, "region": v.Region, "instance_type": v.Type,
		"account": acct,
		"spec": obj{"vcpus": nk(f.Spec.VCPUs), "memory_mib": nk(f.Spec.MemoryMiB), "gpu": nz(f.Spec.GPU),
			"gpu_memory_mib": nk(f.Spec.GPUMemoryMiB)},
		"quota": obj{"vcpus": nk(f.Spec.VCPUs), "on_demand": nk(f.QuotaOnDemand), "spot": nk(f.QuotaSpot)},
		"res": obj{"volumes_gb": nk(f.Volumes), "snapshots": nk(f.Snapshots), "snapshots_gb": nk(f.SnapGB),
			"images": nk(f.Images), "elastic_ips": nk(f.EIPs), "key_pair": nk(f.KeyPair), "security_group": nk(f.SecGroup)},
		"config": obj{"disk_gb": v.configDisk(), "spot": v.configSpot(), "instance_type": v.Type,
			"notifications": v.Flags.Notifications, "tailscale_api_key": v.Flags.TailscaleAPIKey, "alert_email": v.Flags.AlertEmail},
		"build":   obj{"last_min": nk(v.LastBuildMin)},
		"budget":  obj{"alerts": nk(f.BudgetAlerts)},
		"local":   obj{"tailscale": f.Tailscale, "moonlight": f.Moonlight, "ssh_key": f.SSHKey, "auth_key": f.AuthKeyKnown()},
		"tailnet": obj{"node": nz(f.Node.Name), "ip": nz(f.Node.IP), "online": f.Node.Online},
		"archive": v.archiveJSON(),
		"login":   v.loginJSON(),
	}
	if f.ErrorMessage != "" {
		out["error"] = obj{"cause": f.ErrorCause, "credentials": f.ErrorMessage}
	}
	if f.BudgetLimit.OK {
		out["budget"].(obj)["limit"] = f.BudgetLimit.V
		out["budget"].(obj)["spent"] = nk(f.BudgetSpent)
	}
	if f.Legacy.OK && f.Legacy.V != nil {
		out["old_volume"] = obj{"id": f.Legacy.V.ID, "gb": f.Legacy.V.GB, "az": f.Legacy.V.AZ}
	}
	// A box that does not exist is null, not an object of empty strings. The
	// same for a session: no pid means nothing is streaming from this laptop.
	out["box"], out["session"] = nil, nil
	if f.Box.OK && f.Box.V != nil {
		b := f.Box.V
		out["box"] = obj{"id": b.ID, "state": b.State, "type": b.Type, "public_ip": nz(b.PublicIP),
			"launched": b.Launched.UTC().Format("2006-01-02T15:04:05+00:00"), "lifecycle": b.Lifecycle,
			"az": nz(b.AZ), "disk_gb": nk(b.DiskGB), "built": b.Built, "ready": nk(b.Ready)}
		if b.State != "running" {
			delete(out["box"].(obj), "ready")
			delete(out["box"].(obj), "built")
		}
	}
	if f.Session.OK {
		s := obj{"pid": f.Session.V.PID}
		if f.Session.V.Started > 0 {
			s["started"] = f.Session.V.Started
			s["age_s"] = int64(v.Now.Sub(time.Unix(f.Session.V.Started, 0)).Seconds())
		}
		out["session"] = s
	}
	out["rates"] = obj{
		"s3_gb_month": nf(r.S3GBMonth), "ebs_gb_month": nf(r.EBSGBMonth), "snapshot_gb_month": nf(r.SnapshotGBMonth),
		"ipv4_hour": nf(r.IPv4Hour), "inr_per_usd": nf(r.INRPerUSD), "fx_inr_per_usd": nf(r.FXINRPerUSD),
		"tax_pct": r.TaxPct, "ce_call_usd": nf(r.CECallUSD), "egress_gb": nf(r.EgressGB), "egress_free_gb": r.EgressFreeGB,
		"month_hours": time.Date(v.Now.Year(), v.Now.Month()+1, 0, 0, 0, 0, 0, time.UTC).Day() * 24,
	}
	return json.MarshalIndent(out, "", "  ")
}

func (v View) archiveJSON() obj {
	a, f := v.Facts.Archive, v.Facts
	o := obj{"bucket": nz(a.Bucket), "expiry_days": f.ExpiryDays, "decision": nz(f.Decision)}
	if a.Bucket == "" {
		return o
	}
	if a.Err != "" {
		o["error"] = a.Err // objects, bytes and usd_month are then unknown
		o["objects"], o["bytes"], o["usd_month"] = nil, nil, nil
		return o
	}
	o["objects"], o["bytes"], o["usd_month"] = a.Objects, a.Bytes, nil
	if v.Rates.S3GBMonth != nil {
		o["usd_month"], _ = jsonNumber(fmt.Sprintf("%.2f", float64(a.Bytes)/1073741824**v.Rates.S3GBMonth))
	}
	return o
}

func jsonNumber(s string) (json.Number, error) { return json.Number(s), nil }

func (v View) loginJSON() obj {
	a := v.Facts.Archive
	o := obj{"present": nil, "bytes": nil, "pushed": nil}
	if a.Bucket == "" || !a.Login.Present.OK {
		return o
	}
	o["present"], o["bytes"], o["pushed"] = a.Login.Present.V, a.Login.Bytes, nz(a.Login.Pushed)
	return o
}
