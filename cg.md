# cg - the command line

`cg` does everything the app does. The app only runs it and shows what it says.

## Set up

    git clone https://github.com/jebin2/aws_cloud_gaming.git
    cd aws_cloud_gaming
    ./cg check --fix

`check --fix` installs what this computer is missing (AWS CLI, Tailscale, Moonlight, OpenSSH,
curl, python3), signs in to Tailscale and AWS, and asks for any missing setting. It asks before
installing anything.

Settings live in `.env` in the repository, or `~/.config/cg/.env` for the installed app.

## Play on your own server

    ./cg host add homeserver --ssh user@192.168.1.10   # asks the SSH password once
    ./cg host setup homeserver                         # Tailscale, Sunshine, Steam, pairing
    ./cg host open homeserver                          # stream

Setup asks for the server's sudo password. Run it again to repair anything.

## Play on AWS

    ./cg init       # build the machine and restore your games (10-20 min)   [bills hourly]
    ./cg open       # stream
    ./cg destroy    # save your games, then delete the machine - billing stops

Closing Moonlight ends the session but not the machine. It keeps billing until auto-stop ends
it (after 30 idle minutes by default) or you run `cg destroy`.

## Check

    ./cg status            # what exists, and whether every safeguard is on
    ./cg cost              # spend this month   (one AWS call, about ₹1)
    ./cg library list      # saved games and what storing them costs
    ./cg ping              # latency, and whether the connection is direct

## Settings

    ./cg config                              # every setting and its value
    ./cg config set GAME_RES 1920x1080       # change one
    ./cg library keep-for 14                 # days saved games are kept with no machine

## When something is wrong

    ./cg check             # every preflight check; changes nothing
    ./cg log build         # the machine's build log
    ./cg watcher           # each safeguard, and what it last decided

Moonlight's own log is at `~/.cache/cg/moonlight.log`.

## Remove

    ./cg host remove homeserver    # takes cg's SSH key off the server
    ./cg aws disconnect            # delete everything cg made in AWS, in every region

Every command: [docs/commands.md](docs/commands.md).
