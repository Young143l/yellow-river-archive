#!/bin/sh
# 重生成 8 张插图：PlantUML + graphviz 自动布局，输出到 图/
cd "$(dirname "$0")"
rm -rf 图 && mkdir -p 图
plantuml -tpng -o "$(pwd)/图" puml/*.puml
ls -la 图/
