

resize_img() {
    e2fsck -pf "$1" || return 1
    if [ "$2" ]; then
        resize2fs "$1" "$2" || return 1
    else
        resize2fs -M "$1" || return 1
    fi
    return 0
}

loop_setup() {
  unset LOOPDEV
  local LOOP
  local MINORX=1
  [ -e /dev/block/loop1 ] && MINORX=$(stat -Lc '%T' /dev/block/loop1)
  local NUM=0
  while [ $NUM -lt 2048 ]; do
    LOOP=/dev/block/loop$NUM
    [ -e $LOOP ] || mknod $LOOP b 7 $((NUM * MINORX))
    if losetup $LOOP "$1" 2>/dev/null; then
      LOOPDEV=$LOOP
      break
    fi
    NUM=$((NUM + 1))
  done
}

sizeof(){
    EXTRA="$2"
    [ -z "$EXTRA" ] && EXTRA=0
    [ "$EXTRA" -gt 0 ] || EXTRA=0
    size="$(du -s "$1" | awk '{ print $1 }')"
    # append more 20Mb
    size="$((size + EXTRA))"
    echo -n "$((size + 20000))"
}


handle() {
  if [ ! -L "/$1" ] && [ -d "/$1" ] && [ -d "$MODPATH/system/$1" ]; then
    rm -rf "$MODPATH/overlay/$1"
    mv -f "$MODPATH/overlay/system/$1" "$MODPATH/overlay"
    ln -s "../$1" "$MODPATH/overlay/system/$1"
  fi
}

create_ext4_image() {
    dd if=/dev/zero of="$1" bs=1024 count=100
    /system/bin/mkfs.ext4 "$1" && return 0
    return 1
}

support_overlayfs() {

#OVERLAY_IMAGE_EXTRA - number of kb need to be added to overlay.img
#OVERLAY_IMAGE_SHRINK - shrink overlay.img or not?

if [ -d "$MODPATH/system" ]; then
    OVERLAY_IMAGE_SIZE="$(sizeof "$MODPATH/system" "$OVERLAY_IMAGE_EXTRA")"
    rm -rf "$MODPATH/overlay.img"
    create_ext4_image "$MODPATH/overlay.img"
    resize_img "$MODPATH/overlay.img" "${OVERLAY_IMAGE_SIZE}M" || { ui_print "! Setup failed"; return 1; }
    ui_print "- Created overlay image with size: $(du -shH "$MODPATH/overlay.img" | awk '{ print $1 }')"
    loop_setup "$MODPATH/overlay.img"
    if [ ! -z "$LOOPDEV" ]; then
        rm -rf "$MODPATH/overlay"
        mkdir "$MODPATH/overlay"
        mount -t ext4 -o rw "$LOOPDEV" "$MODPATH/overlay"
        chcon u:object_r:system_file:s0 "$MODPATH/overlay"
        cp -afT "$MODPATH/system" "$MODPATH/overlay/system"
        # fix context
        ( cd "$MODPATH" || exit 
          find "system" | while read line; do
            chcon "$(ls -Zd "$line" | awk '{ print $1 }')" "$MODPATH/overlay/$line"
            if [ -e "$line/.replace" ]; then
              setfattr -n trusted.overlay.opaque -v y "$MODPATH/overlay/$line"
            fi
          done
        )
        
        # handle partition
        handle vendor
        handle product
        handle system_ext
        umount -l "$MODPATH/overlay"

        if [ "$OVERLAY_IMAGE_SHRINK" == "true" ] || [ -z "$OVERLAY_IMAGE_SHRINK" ]; then
          ui_print "- Shrink overlay image"
          resize_img "$MODPATH/overlay.img"
          ui_print "- Overlay image new size: $(du -shH "$MODPATH/overlay.img" | awk '{ print $1 }')"
        fi
        rm -rf "$MODPATH/overlay"
        if [ "$INCLUDE_MAGIC_MOUNT" == "true" ]; then
            if [ -f "$MODPATH/post-fs-data.sh" ]; then
                mv -f "$MODPATH/post-fs-data.sh" "$MODPATH/post-fs-data_orig.sh"
            fi
            cat <<EOF >"$MODPATH/post-fs-data.sh"
loop_setup() {
  unset LOOPDEV
  local LOOP
  local MINORX=1
  [ -e /dev/block/loop1 ] && MINORX=\$(stat -Lc '%T' /dev/block/loop1)
  local NUM=0
  while [ \$NUM -lt 2048 ]; do
    LOOP=/dev/block/loop\$NUM
    [ -e \$LOOP ] || mknod \$LOOP b 7 \$((NUM * MINORX))
    if losetup \$LOOP "\$1" 2>/dev/null; then
      LOOPDEV=\$LOOP
      break
    fi
    NUM=\$((NUM + 1))
  done
}

MODDIR="\${0%/*}"
MODNAME="\${MODDIR##*/}"
if [ "\$KSU" == true ]; then
    MODPATH="\$MODDIR"
    MODULESYSTEM="\$MODDIR/overlay"
else
    MAGISKTMP="\$(magisk --path)" || MAGISKTMP=/sbin
    MODPATH="\$MAGISKTMP/.magisk/modules/\$MODNAME"
    MODULESYSTEM="\$MODPATH/overlay"
fi

rm -rf "\$MODDIR/overlay"
rm -rf "\$MODDIR/system"
rm -rf "\$MODDIR/vendor"
rm -rf "\$MODDIR/product"
rm -rf "\$MODDIR/system_ext"
mkdir "\$MODDIR/system"

mkdir "\$MODDIR/overlay"

loop_setup "\$MODDIR/overlay.img"

mount_back() {
    if [ -d "\$MODULESYSTEM/\$1" ]; then
        mkdir "\$MODPATH/system/\$1"
        mount --bind "\$MODULESYSTEM/\$1" "\$MODPATH/system/\$1"
    fi
}

if [ ! -z "\$LOOPDEV" ]; then
    mount -t ext4 -o rw "\$LOOPDEV" "\$MODULESYSTEM"
    if [ "\$KSU" == true ]; then
        mkdir "\$MODDIR/vendor"
        mkdir "\$MODDIR/product"
        mkdir "\$MODDIR/system_ext"
        mount --bind "\$MODULESYSTEM/system" "\$MODPATH/system"
        mount --bind "\$MODULESYSTEM/vendor" "\$MODPATH/vendor"
        mount --bind "\$MODULESYSTEM/product" "\$MODPATH/product"
        mount --bind "\$MODULESYSTEM/system_ext" "\$MODPATH/system_ext"
    else
        mount_back vendor
        mount_back product
        mount_back system_ext
        for i in \$(ls "\$MODULESYSTEM/system"); do
            SRC="\$MODULESYSTEM/system/\$i"
            DEST="\$MODPATH/system/\$i"
            if [ -L "\$SRC" ] || [ -e "\$DEST" ]; then
                continue
            fi
            if [ -d "\$SRC" ]; then
                mkdir "\$DEST"
            else
                echo -n >>"\$DEST"
            fi
            mount --bind "\$SRC" "\$DEST"
        done
    fi
fi
[ -f "\$MODDIR/post-fs-data_orig.sh" ] && exec sh -o standalone "\$MODDIR/post-fs-data_orig.sh"
exit 0
EOF
        fi
        return 0
    fi
fi

return 1
}