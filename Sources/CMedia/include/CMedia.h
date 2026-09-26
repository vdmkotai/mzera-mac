#pragma once
#include <CoreVideo/CoreVideo.h>
#include <sqlite3.h>
#include <stdint.h>

typedef struct MZDecoder MZDecoder;
typedef struct {
    int kind; // 1 video, 2 audio; payload valid until next call, retain/copy to keep.
    double seconds;
    CVPixelBufferRef pixel;
    const float *left;
    const float *right;
    int samples;
    int hardware;
    int full_range;
    int bt601;
    int bt2020;
} MZFrame;

MZDecoder *mz_open(const char *path, int audio, int hardware, char *error, int error_size);
int mz_next(MZDecoder *decoder, MZFrame *frame); // 1 frame, 0 EOF, -1 error
int mz_seek(MZDecoder *decoder, double seconds);
void mz_close(MZDecoder *decoder);
double mz_duration(MZDecoder *decoder);
double mz_probe_duration(const char *path); // Without opening decoders; -1 on error, 0 unknown.
void mz_set_audio_enabled(MZDecoder *decoder, int enabled);
void mz_set_video_limit(MZDecoder *decoder, int limit); // Software export size; 0 = full.

typedef struct MZAnimation MZAnimation;
MZAnimation *mz_animation_open(const char *path);
int mz_animation_next(MZAnimation *animation, const uint8_t **rgba, int *width, int *height, int *delay_ms);
void mz_animation_reset(MZAnimation *animation);
void mz_animation_close(MZAnimation *animation);
