package provision

// Problem is a launch failure in words for a person, and the stable name the
// app picks its buttons by. The text is written for someone looking at a window:
// no ids, setting names, quota codes, AWS service names or commands. What AWS
// said, and its error code, travel beside it as Details.
type Problem struct {
	// Kind is the stable part. A screen follows it, not the words.
	Kind string
	// Title is what went wrong; Text what to do about it.
	Title, Text string
	// Charging says whether money is still being spent: "no" (nothing was
	// started), or "other" (nothing was started by this build, but a game PC
	// from before is still charging).
	Charging string
}

// Problem kinds.
const (
	NoCapacity     = "no_capacity"
	SpotSlotHeld   = "spot_slot_held"
	SpotSlotLeave  = "spot_slot_leaving"
	LimitTooSmall  = "limit"
	KeyMissing     = "key_missing"
	NotAllowed     = "not_allowed"
	NotEnabled     = "not_enabled"
	SignInRefused  = "sign_in_refused"
	AccountBlocked = "account_blocked"
	Unknown        = "unknown"
)

// Plain is the failure as a Problem. Every AWS code Report knows is mapped; the
// rest is Unknown, which still says that nothing was started.
func (f LaunchFailure) Plain() Problem {
	live := false
	for _, h := range f.Holders {
		if h.State != "shutting-down" {
			live = true
		}
	}
	p := Problem{Charging: "no"}
	if live {
		p.Charging = "other"
	}
	switch f.Code {
	case "InsufficientInstanceCapacity", "SpotMaxPriceTooLow":
		p.Kind = NoCapacity
		if f.Spot {
			p.Title = "AWS has no cheap game PCs free here right now"
			p.Text = "Try again in a few minutes, or pick another place or machine. A normal-price game PC usually works when the cheap ones run out."
		} else {
			p.Title = "AWS has no game PCs of this kind free here right now"
			p.Text = "Pick another machine or another place, or try again later. Capacity usually comes back within hours."
		}
	case "MaxSpotInstanceCountExceeded":
		switch {
		case live:
			p.Kind, p.Title = SpotSlotHeld, "A game PC you started earlier is still there"
			p.Text = "It is still charging, and it uses up your allowance for cheap game PCs. Delete it, then build again."
		default:
			p.Kind, p.Title = SpotSlotLeave, "Your last game PC is still shutting down"
			p.Text = "AWS frees its place in a minute or two. Try again then."
		}
	case "VcpuLimitExceeded", "InstanceLimitExceeded":
		// Another game PC is what is using the allowance: wait for it, or delete it.
		// Asking AWS for more would not help, and the permission is not what is missing.
		stopping := false
		for _, h := range f.Holders {
			if h.State == "stopping" {
				stopping = true
			}
		}
		switch {
		case f.Code == "VcpuLimitExceeded" && stopping:
			p.Kind, p.Title = SpotSlotLeave, "Your last game PC is still shutting down"
			p.Text = "It is saving your games first, which can take several minutes. Try again when it has stopped."
		case f.Code == "VcpuLimitExceeded" && live:
			p.Kind, p.Title = SpotSlotHeld, "A game PC you started earlier is still there"
			p.Text = "It is still charging, and it uses up your allowance for game PCs. Delete it, then build again."
		case f.Code == "VcpuLimitExceeded" && len(f.Holders) > 0:
			p.Kind, p.Title = SpotSlotLeave, "Your last game PC is still shutting down"
			p.Text = "AWS frees its place in a minute or two. Try again then."
		default:
			p.Kind, p.Title = LimitTooSmall, "AWS has not yet allowed you to run this game PC here - ask for permission, or try again later"
			p.Text = "Asking is free, but AWS can take a while to answer. If you only just deleted a game PC, trying again in a minute or two may be all it needs."
		}
	case "InvalidKeyPair.NotFound":
		p.Kind, p.Title = KeyMissing, "This place is missing the key the app uses to set up your game PC"
		p.Text = "Fix it, then build again."
	case "AccessDenied", "AccessDeniedException", "UnauthorizedOperation":
		p.Kind, p.Title = NotAllowed, "Your AWS sign-in is not allowed to start game PCs"
		p.Text = "Connect AWS again with a sign-in that is allowed to, then build again."
	case "OptInRequired", "SubscriptionRequiredException":
		p.Kind, p.Title = NotEnabled, "AWS has not turned this place on for your account"
		p.Text = "Choose another place, or turn this one on in your AWS account. Turning it on is free."
	case "AuthFailure":
		p.Kind, p.Title = SignInRefused, "AWS did not accept your sign-in"
		p.Text = "Connect AWS again. If that does not help, look for a notice in your AWS account."
	case "UnauthorizedAccount", "Blocked":
		p.Kind, p.Title = AccountBlocked, "AWS has paused something on your account"
		p.Text = "Open your AWS account and read the notice at the top. Trying again will not fix this."
	default:
		p.Kind, p.Title = Unknown, "The game PC could not be started"
		p.Text = "See the details for what AWS said, then try again."
	}
	return p
}
