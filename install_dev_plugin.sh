#!/bin/bash

xcodebuild -configuration  Development  -target ChristmasTreeVisualizer

ITUNES_PLUGINS_FOLDER=${HOME}/Library/iTunes/iTunes\ Plug-ins;

echo "Installing Plugin\n"
cp -r build/Development/Christmas.bundle "${ITUNES_PLUGINS_FOLDER}/"

killall VisualizerService;
echo "Done";