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
} MZFrame;

MZDecoder *mz_open(const char *path, int audio, int hardware, char *error, int error_size);
int mz_next(MZDecoder *decoder, MZFrame *frame); // 1 frame, 0 EOF, -1 error
int mz_seek(MZDecoder *decoder, double seconds);
void mz_close(MZDecoder *decoder);
double mz_duration(MZDecoder *decoder);
