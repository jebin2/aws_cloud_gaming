# ayis - the command line

`ayis` does everything the app does. The app only runs it and shows what it says.

## Set up

    git clone https://github.com/jebin2/ayis.git
    cd ayis
    ./ayis check --fix

`check --fix` installs what this computer is missing (AWS CLI, Tailscale, Moonlight, OpenSSH,
curl, python3), signs in to Tailscale and AWS, and asks for any missing setting. It asks before
installing anything.

Settings live in `.env` in the repository, or `~/.config/ayis/.env` for the installed app.

## Play on your own server

    ./ayis host add homeserver --ssh user@192.168.1.10   # asks the SSH password once
    ./ayis host setup homeserver                         # Tailscale, Sunshine, Steam, pairing
    ./ayis host open homeserver                          # stream

Setup asks for the server's sudo password. Run it again to repair anything.

## Play on AWS

    ./ayis init       # build the machine and restore your games (10-20 min)   [bills hourly]
    ./ayis open       # stream
    ./ayis destroy    # save your games, then delete the machine - billing stops

Closing Moonlight ends the session but not the machine. It keeps billing until auto-stop ends
it (after 30 idle minutes by default) or you run `ayis destroy`.

## Check

    ./ayis status            # what exists, and whether every safeguard is on
    ./ayis cost              # spend this month   (one AWS call, about ₹1)
    ./ayis library list      # saved games and what storing them costs
    ./ayis ping              # latency, and whether the connection is direct

## Settings

    ./ayis config                              # every setting and its value
    ./ayis config set GAME_RES 1920x1080       # change one
    ./ayis library keep-for 14                 # days saved games are kept with no machine

## When something is wrong

    ./ayis check             # every preflight check; changes nothing
    ./ayis log build         # the machine's build log
    ./ayis watcher           # each safeguard, and what it last decided

Moonlight's own log is at `~/.cache/ayis/moonlight.log`.

## Remove

    ./ayis host remove homeserver    # takes ayis's SSH key off the server
    ./ayis aws disconnect            # delete everything ayis made in AWS, in every region

Every command: [docs/commands.md](docs/commands.md).
