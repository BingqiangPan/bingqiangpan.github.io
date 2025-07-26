#!/bin/bash

filename="_posts/$1"
title=$2
date=$(date +"%Y-%m-%d %H:%M:%S %z")

cat <<EOF > "$filename"
---
title: "$title"
author: B. Pan
date: $date
categories: [Blogging]
tags: [General]
pin: false
---

Main content
EOF