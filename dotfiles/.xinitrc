while true; do
    xsetroot -name "$(date +'%F %T')"
    sleep 1
done &

exec dwm
