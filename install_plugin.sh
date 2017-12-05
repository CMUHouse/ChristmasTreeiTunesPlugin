#!/bin/bash

xcodebuild -configuration  Deployment  -target ChristmasTreeVisualizer

ITUNES_PLUGINS_FOLDER=${HOME}/Library/iTunes/iTunes\ Plug-ins;

echo "Installing Plugin\n"
cp -r build/Deployment/Christmas.bundle "${ITUNES_PLUGINS_FOLDER}/"

killall VisualizerService;
echo "Done";