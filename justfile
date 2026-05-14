test:
    bash -n ref/*.sh
    bash ref/build-image.sh
    bash ref/verify.sh
