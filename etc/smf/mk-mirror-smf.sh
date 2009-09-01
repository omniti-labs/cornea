#!/bin/sh

METANODE=$1

if [ -z "$METANODE" ]; then
	echo "$0 <remote-metanode>"
	exit
fi

sed -e "s/@@METANODE@@/$METANODE/g;" \
	< cornea-mirror-metanode.xml.tmpl \
	> cornea-mirror-$METANODE.xml
