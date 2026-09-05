#include "CMedia.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <VideoToolbox/VideoToolbox.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <webp/demux.h>
#include <webp/decode.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

struct MZDecoder {
    AVFormatContext *format;
    AVCodecContext *video, *audio;
    AVBufferRef *device;
    AVPacket *packet;
    AVFrame *frame;
    struct SwsContext *sws;
    SwrContext *swr;
    int vi, ai, receiving, eof, draining;
    CVPixelBufferRef pixel;
    float *samples[2];
    int capacity;
    CVPixelBufferPoolRef pool;
    int pool_width, pool_height, sws_space, sws_range, errors;
    int sws_width, sws_height, sws_format, sws_output_width, sws_output_height;
    int audio_enabled, video_limit;
};

static pthread_once_t vp9_once = PTHREAD_ONCE_INIT;
static void register_vp9(void) { VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9); }

static enum AVPixelFormat choose_format(AVCodecContext *ctx, const enum AVPixelFormat *formats) {
    for (const enum AVPixelFormat *p = formats; *p != AV_PIX_FMT_NONE; p++)
        if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
    return formats[0];
}

static AVCodecContext *open_codec(MZDecoder *d, int stream, int hw) {
    AVCodecParameters *par = d->format->streams[stream]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(par->codec_id);
    if (!codec) return NULL;
    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx || avcodec_parameters_to_context(ctx, par) < 0) { avcodec_free_context(&ctx); return NULL; }
    ctx->thread_count = 2; // Bound codec-internal threads as well as outer workers.
    ctx->max_pixels = 100000000;
    if (hw) {
        pthread_once(&vp9_once, register_vp9);
        if (av_hwdevice_ctx_create(&d->device, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) >= 0) {
            ctx->hw_device_ctx = av_buffer_ref(d->device);
            ctx->get_format = choose_format;
        }
    }
    if (avcodec_open2(ctx, codec, NULL) < 0) { avcodec_free_context(&ctx); return NULL; }
    return ctx;
}

MZDecoder *mz_open(const char *path, int audio, int hardware, char *error, int error_size) {
    MZDecoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->vi = d->ai = -1;
    d->audio_enabled = audio;
    d->sws_space = d->sws_range = -1;
    AVDictionary *options = NULL;
    av_dict_set(&options, "protocol_whitelist", "file", 0);
    int result = avformat_open_input(&d->format, path, NULL, &options);
    av_dict_free(&options);
    if (result < 0) goto fail;
    if ((result = avformat_find_stream_info(d->format, NULL)) < 0) goto fail;
    d->vi = av_find_best_stream(d->format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (d->vi < 0) { result = d->vi; goto fail; }
    d->video = open_codec(d, d->vi, hardware);
    if (!d->video) { result = AVERROR_DECODER_NOT_FOUND; goto fail; }
    if (audio) {
        d->ai = av_find_best_stream(d->format, AVMEDIA_TYPE_AUDIO, -1, d->vi, NULL, 0);
        if (d->ai >= 0) d->audio = open_codec(d, d->ai, 0);
        if (d->audio) {
            AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
            if (swr_alloc_set_opts2(&d->swr, &stereo, AV_SAMPLE_FMT_FLTP, 48000,
                                  &d->audio->ch_layout, d->audio->sample_fmt, d->audio->sample_rate, 0, NULL) < 0 ||
                swr_init(d->swr) < 0) { swr_free(&d->swr); avcodec_free_context(&d->audio); }
        }
        if (!d->audio) d->ai = -1;
    }
    d->packet = av_packet_alloc(); d->frame = av_frame_alloc();
    if (!d->packet || !d->frame) { result = AVERROR(ENOMEM); goto fail; }
    return d;
fail:
    if (error && error_size > 0) av_strerror(result, error, error_size);
    mz_close(d); return NULL;
}

static int export_frame(MZDecoder *d, MZFrame *out, int kind) {
    AVFrame *f = d->frame;
    int stream = kind == 1 ? d->vi : d->ai;
    AVStream *s = d->format->streams[stream];
    int64_t stamp = f->best_effort_timestamp;
    out->seconds = stamp == AV_NOPTS_VALUE ? 0 : stamp * av_q2d(s->time_base);
    if (d->format->start_time != AV_NOPTS_VALUE) out->seconds -= d->format->start_time / (double)AV_TIME_BASE;
    out->seconds = out->seconds < 0 ? 0 : out->seconds;
    out->kind = kind;
    if (kind == 2) {
        if (!d->audio_enabled) return 1; // Decode for continuity, avoid resampling while muted.
        int count = swr_get_out_samples(d->swr, f->nb_samples);
        if (count < 0 || count > 96000) return -1;
        if (count > d->capacity) {
            av_freep(&d->samples[0]); av_freep(&d->samples[1]);
            d->samples[0] = av_malloc_array(count, sizeof(float));
            d->samples[1] = av_malloc_array(count, sizeof(float));
            if (!d->samples[0] || !d->samples[1]) return -1;
            d->capacity = count;
        }
        uint8_t *dst[] = {(uint8_t *)d->samples[0], (uint8_t *)d->samples[1]};
        out->samples = swr_convert(d->swr, dst, count, (const uint8_t **)f->extended_data, f->nb_samples);
        out->left = d->samples[0]; out->right = d->samples[1];
        return out->samples >= 0 ? 1 : -1;
    }
    if (f->width <= 0 || f->height <= 0 || (int64_t)f->width * f->height > 100000000) return -1;
    out->hardware = f->format == AV_PIX_FMT_VIDEOTOOLBOX;
    out->full_range = f->color_range == AVCOL_RANGE_JPEG;
    out->bt601 = f->colorspace == AVCOL_SPC_BT470BG || f->colorspace == AVCOL_SPC_SMPTE170M;
    out->bt2020 = f->colorspace == AVCOL_SPC_BT2020_NCL || f->colorspace == AVCOL_SPC_BT2020_CL;
    if (out->hardware) {
        d->pixel = CVPixelBufferRetain((CVPixelBufferRef)f->data[3]);
    } else {
        int width = f->width, height = f->height;
        int largest = width > height ? width : height;
        if (d->video_limit > 0 && largest > d->video_limit) {
            width = (int)((int64_t)width * d->video_limit / largest);
            height = (int)((int64_t)height * d->video_limit / largest);
            if (width < 1) width = 1;
            if (height < 1) height = 1;
        }
        if (!d->pool || width != d->pool_width || height != d->pool_height) {
        if (d->pool) { CVPixelBufferPoolRelease(d->pool); d->pool = NULL; }
        const void *keys[] = {kCVPixelBufferMetalCompatibilityKey, kCVPixelBufferIOSurfacePropertiesKey, kCVPixelBufferWidthKey, kCVPixelBufferHeightKey, kCVPixelBufferPixelFormatTypeKey};
        CFDictionaryRef empty = CFDictionaryCreate(NULL, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        int format = kCVPixelFormatType_32BGRA;
        CFNumberRef wn = CFNumberCreate(NULL, kCFNumberIntType, &width), hn = CFNumberCreate(NULL, kCFNumberIntType, &height), fn = CFNumberCreate(NULL, kCFNumberIntType, &format);
        const void *values[] = {kCFBooleanTrue, empty, wn, hn, fn};
        CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 5, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CVReturn result = CVPixelBufferPoolCreate(NULL, NULL, attrs, &d->pool);
        CFRelease(attrs); CFRelease(empty); CFRelease(wn); CFRelease(hn); CFRelease(fn);
        if (result != kCVReturnSuccess) return -1;
        d->pool_width = width; d->pool_height = height;
        }
        if (CVPixelBufferPoolCreatePixelBuffer(NULL, d->pool, &d->pixel) != kCVReturnSuccess) return -1;
        int changed = !d->sws || f->width != d->sws_width || f->height != d->sws_height ||
            f->format != d->sws_format || width != d->sws_output_width || height != d->sws_output_height;
        d->sws = sws_getCachedContext(d->sws, f->width, f->height, f->format, width, height,
                                   AV_PIX_FMT_BGRA, SWS_BILINEAR, NULL, NULL, NULL);
        if (!d->sws) return -1;
        int colorspace = out->bt2020 ? SWS_CS_BT2020 : (out->bt601 ? SWS_CS_ITU601 : SWS_CS_ITU709);
        if (changed || colorspace != d->sws_space || out->full_range != d->sws_range) {
        const int *coefficients = sws_getCoefficients(colorspace);
        if (sws_setColorspaceDetails(d->sws, coefficients, out->full_range, coefficients, 1, 0, 1<<16, 1<<16) < 0) return -1;
        d->sws_space = colorspace; d->sws_range = out->full_range;
        d->sws_width = f->width; d->sws_height = f->height; d->sws_format = f->format;
        d->sws_output_width = width; d->sws_output_height = height;
        }
        CVPixelBufferLockBaseAddress(d->pixel, 0);
        uint8_t *data[] = {CVPixelBufferGetBaseAddress(d->pixel)};
        int stride[] = {(int)CVPixelBufferGetBytesPerRow(d->pixel)};
        sws_scale(d->sws, (const uint8_t *const *)f->data, f->linesize, 0, f->height, data, stride);
        const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(f->format);
        if (description && (description->flags & AV_PIX_FMT_FLAG_ALPHA)) {
            for (int y = 0; y < height; ++y) {
                uint8_t *row = data[0] + y * stride[0];
                for (int x = 0; x < width; ++x) {
                    uint8_t *p = row + x * 4;
                    for (int c = 0; c < 3; ++c) p[c] = (p[c] * p[3] + 127) / 255;
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(d->pixel, 0);
    }
    out->pixel = d->pixel;
    return 1;
}

int mz_next(MZDecoder *d, MZFrame *out) {
    memset(out, 0, sizeof(*out));
    if (d->pixel) { CVPixelBufferRelease(d->pixel); d->pixel = NULL; }
    for (;;) {
        if (d->receiving) {
            int kind = d->receiving;
            AVCodecContext *ctx = kind == 1 ? d->video : d->audio;
            int result = avcodec_receive_frame(ctx, d->frame);
            if (result == 0) { int exported = export_frame(d, out, kind); av_frame_unref(d->frame); d->errors = 0; return exported; }
            d->receiving = 0;
            if (result != AVERROR(EAGAIN) && result != AVERROR_EOF && (result != AVERROR_INVALIDDATA || ++d->errors > 32)) return -1;
        }
        if (d->eof) {
            if (d->draining == 0) { d->draining = 1; avcodec_send_packet(d->video, NULL); d->receiving = 1; continue; }
            if (d->draining == 1 && d->audio) { d->draining = 2; avcodec_send_packet(d->audio, NULL); d->receiving = 2; continue; }
            return 0;
        }
        int result = av_read_frame(d->format, d->packet);
        if (result == AVERROR_EOF) { d->eof = 1; continue; }
        if (result < 0) { if (result == AVERROR_INVALIDDATA && ++d->errors <= 32) continue; return -1; }
        int kind = d->packet->stream_index == d->vi ? 1 : (d->packet->stream_index == d->ai ? 2 : 0);
        if (kind) {
            result = avcodec_send_packet(kind == 1 ? d->video : d->audio, d->packet);
            av_packet_unref(d->packet);
            if (result < 0) { if (result == AVERROR_INVALIDDATA && ++d->errors <= 32) continue; return -1; }
            d->receiving = kind;
        } else av_packet_unref(d->packet);
    }
}

int mz_seek(MZDecoder *d, double seconds) {
    int64_t offset = d->format->start_time == AV_NOPTS_VALUE ? 0 : d->format->start_time;
    if (av_seek_frame(d->format, -1, (int64_t)(seconds * AV_TIME_BASE) + offset, AVSEEK_FLAG_BACKWARD) < 0) return 0;
    avcodec_flush_buffers(d->video);
    if (d->audio) avcodec_flush_buffers(d->audio);
    if (d->swr) { swr_close(d->swr); swr_init(d->swr); }
    d->receiving = d->eof = d->draining = d->errors = 0;
    return 1;
}
double mz_duration(MZDecoder *d) { return d->format->duration == AV_NOPTS_VALUE ? 0 : d->format->duration/(double)AV_TIME_BASE; }
void mz_set_audio_enabled(MZDecoder *d, int enabled) { d->audio_enabled = enabled; }
void mz_set_video_limit(MZDecoder *d, int limit) { d->video_limit = limit; }
void mz_close(MZDecoder *d) {
    if (!d) return;
    if (d->pixel) CVPixelBufferRelease(d->pixel);
    if (d->pool) CVPixelBufferPoolRelease(d->pool);
    sws_freeContext(d->sws); swr_free(&d->swr);
    av_freep(&d->samples[0]); av_freep(&d->samples[1]);
    avcodec_free_context(&d->video); avcodec_free_context(&d->audio);
    av_buffer_unref(&d->device); av_frame_free(&d->frame); av_packet_free(&d->packet);
    avformat_close_input(&d->format); free(d);
}

struct MZAnimation { WebPAnimDecoder *decoder; uint8_t *data; size_t size; int width, height, timestamp; };
MZAnimation *mz_animation_open(const char *path) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) return NULL;
    struct stat stat;
    if (fstat(fd, &stat) != 0 || stat.st_size <= 0 || stat.st_size > 512LL*1024*1024) { close(fd); return NULL; }
    uint8_t *data = mmap(NULL, stat.st_size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (data == MAP_FAILED) return NULL;
    MZAnimation *a = calloc(1, sizeof(*a));
    if (!a) { munmap(data, stat.st_size); return NULL; }
    a->data = data; a->size = stat.st_size;
    WebPBitstreamFeatures features;
    if (WebPGetFeatures(data, a->size, &features) != VP8_STATUS_OK || features.width <= 0 || features.height <= 0 || (int64_t)features.width*features.height > 16000000) goto fail_animation;
    WebPData source = {data, a->size};
    WebPAnimDecoderOptions options;
    if (!WebPAnimDecoderOptionsInit(&options)) goto fail_animation;
    options.color_mode = MODE_RGBA; options.use_threads = 0;
    a->decoder = WebPAnimDecoderNew(&source, &options);
    WebPAnimInfo info;
    if (!a->decoder || !WebPAnimDecoderGetInfo(a->decoder, &info) || info.frame_count < 2) goto fail_animation;
    a->width = info.canvas_width; a->height = info.canvas_height;
    return a;
fail_animation: mz_animation_close(a); return NULL;
}
int mz_animation_next(MZAnimation *a, const uint8_t **rgba, int *width, int *height, int *delay_ms) {
    if (!WebPAnimDecoderHasMoreFrames(a->decoder)) return 0;
    uint8_t *buffer; int timestamp;
    if (!WebPAnimDecoderGetNext(a->decoder, &buffer, &timestamp)) return -1;
    *rgba = buffer; *width = a->width; *height = a->height;
    *delay_ms = timestamp - a->timestamp; a->timestamp = timestamp;
    return 1;
}
void mz_animation_reset(MZAnimation *a) { WebPAnimDecoderReset(a->decoder); a->timestamp = 0; }
void mz_animation_close(MZAnimation *a) {
    if (!a) return;
    if (a->decoder) WebPAnimDecoderDelete(a->decoder);
    if (a->data) munmap(a->data, a->size);
    free(a);
}
