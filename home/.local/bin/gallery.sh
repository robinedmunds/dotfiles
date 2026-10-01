find . -maxdepth 1 -type f -regextype posix-egrep -iregex '.*\.(avi|mp4|webm|mkv|jpg|webp|png|avif)$' | shuf | mpv --profile=gallery --playlist=-
