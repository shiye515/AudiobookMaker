#include <mach/mach.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <time.h>
#include "sherpa-onnx/c-api/c-api.h"

typedef struct {
  double started;
  double stop_after_seconds;
  int callbacks;
} CancelContext;

static double monotonic_seconds(void) {
  struct timespec value;
  clock_gettime(CLOCK_MONOTONIC, &value);
  return (double)value.tv_sec + (double)value.tv_nsec / 1000000000.0;
}

static const char *architecture_name(void) {
#if defined(__arm64__) || defined(__aarch64__)
  return "arm64";
#elif defined(__x86_64__)
  return "x86_64";
#else
  return "unknown";
#endif
}

static long long resident_bytes(void) {
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
    return -1;
  }
  return (long long)info.resident_size;
}

static long long peak_resident_bytes(void) {
  struct rusage usage;
  if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
  return (long long)usage.ru_maxrss;
}

static int32_t cancel_callback(
    const float *samples, int32_t count, float progress, void *opaque) {
  (void)samples;
  (void)count;
  (void)progress;
  CancelContext *context = (CancelContext *)opaque;
  context->callbacks += 1;
  return monotonic_seconds() - context->started < context->stop_after_seconds;
}

static const SherpaOnnxGeneratedAudio *generate(
    const SherpaOnnxOfflineTts *tts, const char *text, int32_t speaker_id,
    SherpaOnnxGeneratedAudioProgressCallbackWithArg callback, void *context) {
  SherpaOnnxGenerationConfig generation;
  memset(&generation, 0, sizeof(generation));
  generation.sid = speaker_id;
  generation.speed = 1.0f;
  generation.silence_scale = 0.2f;
  return SherpaOnnxOfflineTtsGenerateWithConfig(tts, text, &generation, callback, context);
}

static int write_audio(const SherpaOnnxGeneratedAudio *audio, const char *path) {
  if (!audio || audio->n <= 0 || audio->sample_rate != 24000 || !audio->samples) return 0;
  return SherpaOnnxWriteWave(audio->samples, audio->n, audio->sample_rate, path);
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: kokoro-benchmark MODEL_DIRECTORY OUTPUT_DIRECTORY\n");
    return 64;
  }
  mkdir(argv[2], 0755);
  char model[4096], voices[4096], tokens[4096], data_dir[4096], lexicon[8192];
  snprintf(model, sizeof(model), "%s/model.int8.onnx", argv[1]);
  snprintf(voices, sizeof(voices), "%s/voices.bin", argv[1]);
  snprintf(tokens, sizeof(tokens), "%s/tokens.txt", argv[1]);
  snprintf(data_dir, sizeof(data_dir), "%s/espeak-ng-data", argv[1]);
  snprintf(lexicon, sizeof(lexicon), "%s/lexicon-us-en.txt,%s/lexicon-zh.txt", argv[1], argv[1]);

  SherpaOnnxOfflineTtsConfig config;
  memset(&config, 0, sizeof(config));
  config.model.kokoro.model = model;
  config.model.kokoro.voices = voices;
  config.model.kokoro.tokens = tokens;
  config.model.kokoro.data_dir = data_dir;
  config.model.kokoro.lexicon = lexicon;
  config.model.kokoro.length_scale = 1.0f;
  config.model.provider = "cpu";
  config.model.num_threads = 2;
  config.max_num_sentences = 1;

  long long rss_before = resident_bytes();
  double load_started = monotonic_seconds();
  const SherpaOnnxOfflineTts *tts = SherpaOnnxCreateOfflineTts(&config);
  double cold_load_seconds = monotonic_seconds() - load_started;
  if (!tts) return 2;
  if (SherpaOnnxOfflineTtsSampleRate(tts) != 24000 || SherpaOnnxOfflineTtsNumSpeakers(tts) != 103) return 3;
  long long rss_after_load = resident_bytes();

  const char *first_text = "你好，这是有声书制作器的首段延迟测试。";
  double first_started = monotonic_seconds();
  const SherpaOnnxGeneratedAudio *first = generate(tts, first_text, 3, NULL, NULL);
  double first_seconds = monotonic_seconds() - first_started;
  char first_path[4096];
  snprintf(first_path, sizeof(first_path), "%s/first-segment.wav", argv[2]);
  if (!write_audio(first, first_path)) return 4;
  double first_audio_seconds = (double)first->n / (double)first->sample_rate;
  SherpaOnnxDestroyOfflineTtsGeneratedAudio(first);

  const char *long_text =
      "一九七八年十二月，中国开始了影响深远的改革开放。到二零二六年，人工智能、能源与国际贸易继续改变世界。"
      "李光耀曾多次讨论中国、美国、东南亚以及全球秩序之间的关系。AudiobookMaker version 1.0 将 EPUB 转换成 M4B，"
      "其中百分之三点五、人民币一百二十三元、上午九点三十分和二零二六年七月十九日都需要清楚朗读。"
      "第一章结束。第二章开始：中英文 mixed content、数字 12345、专名 sherpa-onnx 与 Kokoro 应保持自然连贯。";
  double long_wall_seconds = 0;
  double long_audio_seconds = 0;
  for (int index = 0; index < 3; ++index) {
    double segment_started = monotonic_seconds();
    const SherpaOnnxGeneratedAudio *audio = generate(tts, long_text, 3, NULL, NULL);
    long_wall_seconds += monotonic_seconds() - segment_started;
    if (!audio || audio->n <= 0 || audio->sample_rate != 24000) return 5;
    long_audio_seconds += (double)audio->n / (double)audio->sample_rate;
    char path[4096];
    snprintf(path, sizeof(path), "%s/listening-%d.wav", argv[2], index + 1);
    if (!write_audio(audio, path)) return 6;
    SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
  }

  CancelContext cancellation = {
      .started = monotonic_seconds(),
      .stop_after_seconds = 0.1,
      .callbacks = 0,
  };
  const SherpaOnnxGeneratedAudio *cancelled = generate(
      tts, long_text, 3, cancel_callback, &cancellation);
  double cancellation_seconds = monotonic_seconds() - cancellation.started;
  if (cancelled) SherpaOnnxDestroyOfflineTtsGeneratedAudio(cancelled);

  printf("architecture=%s\n", architecture_name());
  printf("voice_id=zf_001\n");
  printf("speaker_id=3\n");
  printf("sample_rate=24000\n");
  printf("speakers=103\n");
  printf("cold_load_seconds=%.6f\n", cold_load_seconds);
  printf("first_segment_wall_seconds=%.6f\n", first_seconds);
  printf("first_segment_audio_seconds=%.6f\n", first_audio_seconds);
  printf("first_segment_rtf=%.6f\n", first_seconds / first_audio_seconds);
  printf("long_segments=3\n");
  printf("long_wall_seconds=%.6f\n", long_wall_seconds);
  printf("long_audio_seconds=%.6f\n", long_audio_seconds);
  printf("long_rtf=%.6f\n", long_wall_seconds / long_audio_seconds);
  printf("cancel_requested_after_seconds=0.100000\n");
  printf("cancel_return_seconds=%.6f\n", cancellation_seconds);
  printf("cancel_callbacks=%d\n", cancellation.callbacks);
  printf("rss_before_bytes=%lld\n", rss_before);
  printf("rss_after_load_bytes=%lld\n", rss_after_load);
  printf("peak_rss_bytes=%lld\n", peak_resident_bytes());
  SherpaOnnxDestroyOfflineTts(tts);
  return 0;
}
