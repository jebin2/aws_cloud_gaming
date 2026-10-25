package games

// remoteScript is what the box is asked: every Steam manifest, the disk, what is
// staged for download, and the inbound rate sampled twice three seconds apart - a
// rate averaged over the whole boot is not the rate right now, and "right now" is
// what an ETA needs. It is the script the Bash cg has always sent, unchanged,
// because it runs on the box.
const remoteScript = `
    for f in /scratch/steam/steamapps/appmanifest_*.acf; do
      [ -f "$f" ] || continue
      id=$(basename "$f" .acf); id=${id#appmanifest_}
      name=$(sed -n "s/.*\"name\"[[:space:]]*\"\(.*\)\".*/\1/p" "$f" | head -1)
      flags=$(sed -n "s/.*\"StateFlags\"[[:space:]]*\"\([0-9]*\)\".*/\1/p" "$f" | head -1)
      size=$(sed -n "s/.*\"SizeOnDisk\"[[:space:]]*\"\([0-9]*\)\".*/\1/p" "$f" | head -1)
      got=$(sed -n "s/.*\"BytesDownloaded\"[[:space:]]*\"\([0-9]*\)\".*/\1/p" "$f" | head -1)
      want=$(sed -n "s/.*\"BytesToDownload\"[[:space:]]*\"\([0-9]*\)\".*/\1/p" "$f" | head -1)
      dir=$(sed -n "s/.*\"installdir\"[[:space:]]*\"\(.*\)\".*/\1/p" "$f" | head -1)
      stage=$(sed -n "s/.*\"BytesToStage\"[[:space:]]*\"\([0-9]*\)\".*/\1/p" "$f" | head -1)
      on=0; pgrep -f "[/]steamapps/common/$dir/" >/dev/null 2>&1 && on=1
      # Steam.s own BytesDownloaded lags badly - it read 0.6 GB with 67 GB on
      # disk - so progress comes from the DISK: what is committed plus what is
      # staged in downloading/, against BytesToStage.
      done_b=$(du -sb "/scratch/steam/steamapps/common/$dir" 2>/dev/null | cut -f1)
      printf "APP\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$id" "$name" "${flags:-0}" "${size:-0}" "${done_b:-0}" "${want:-0}" "$on" "${stage:-0}"
    done
    printf "DISK\t%s\n" "$(df -B1 --output=used,avail /scratch | tail -1 | tr -s " " "\t" | sed "s/^\t//")"
    printf "DL\t%s\n" "$(du -sb /scratch/steam/steamapps/downloading 2>/dev/null | cut -f1 || echo 0)"
    # Two samples three seconds apart: a rate averaged over the whole boot is
    # not the rate right now, and "right now" is what an ETA needs.
    w=$(ip route show default 2>/dev/null | awk "{print \$5; exit}")
    r1=$(cat /sys/class/net/${w:-eth0}/statistics/rx_bytes 2>/dev/null || echo 0)
    sleep 3
    r2=$(cat /sys/class/net/${w:-eth0}/statistics/rx_bytes 2>/dev/null || echo 0)
    printf "RATE\t%s\n" "$(( (r2 - r1) / 3 ))"
`
