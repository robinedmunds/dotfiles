find . -maxdepth 1 -type f -name '*.jpg' -exec sh -c 'exiv2 --verbose --rename "%Y%m%d-%H%M%S-:Exif.Image.Model:-$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)" {}' \;
