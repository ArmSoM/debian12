#!/bin/bash
# ES8316 Audio Setup Script

CARD=2

for i in $(seq 1 10); do
    if [ -e /dev/snd/controlC$CARD ]; then
        break
    fi
    sleep 0.5
done

if [ ! -e /dev/snd/controlC$CARD ]; then
    echo "ES8316 card not found, skipping setup"
    exit 0
fi

amixer -c $CARD cset numid=40 on      # Headphone Switch
amixer -c $CARD cset numid=50 on      # Left DAC Switch
amixer -c $CARD cset numid=52 on      # Right DAC Switch
amixer -c $CARD cset numid=13 6,6     # Headphone Mixer Volume
amixer -c $CARD cset numid=12 1,1     # Headphone Playback Volume
amixer -c $CARD cset numid=15 140,140 # DAC Playback Volume

amixer -c $CARD cset numid=42 on      # Main Mic Switch
amixer -c $CARD cset numid=43 on      # Headset Mic Switch
amixer -c $CARD cset numid=49 on      # LLIN Switch
amixer -c $CARD cset numid=51 on      # RLIN Switch
amixer -c $CARD cset numid=24 192     # ADC Capture Volume
amixer -c $CARD cset numid=25 10      # ADC PGA Gain
amixer -c $CARD cset numid=28 off     # ALC Capture Switch 

echo "ES8316 audio setup completed"