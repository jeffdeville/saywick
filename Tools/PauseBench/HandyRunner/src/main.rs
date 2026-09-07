use anyhow::{bail, Result};
use serde_json::json;
use std::{env, fs, time::{Duration, Instant}};
use transcribe_cpp::{Model, RunOptions, StreamOptions};
include!(concat!(env!("OUT_DIR"), "/handy_audio.rs"));
use audio_toolkit::vad::*;

fn main() -> Result<()> {
    let args: Vec<_> = env::args().collect();
    if args.len() != 6 { bail!("Usage: pause-bench-handy MODEL WAV RESULT_JSON SILERO_MODEL <silero|earshot|off>"); }
    let mut wav = hound::WavReader::open(&args[2])?;
    let spec = wav.spec();
    if spec.sample_rate != 16000 || spec.channels != 1 || spec.bits_per_sample != 16 || spec.sample_format != hound::SampleFormat::Int {
        bail!("Expected 16 kHz mono PCM16 WAV");
    }
    let pcm: Vec<f32> = wav.samples::<i16>().map(|s| s.map(|v| v as f32 / 32768.0)).collect::<Result<_,_>>()?;
    let detector: Box<dyn VoiceActivityDetector> = match args[5].as_str() {
        "silero" => Box::new(SileroVad::new(&args[4], 0.3)?),
        "earshot" => Box::new(EarshotVad::new(0.5)?),
        "off" => Box::new(EarshotVad::new(0.5)?),
        _ => bail!("Unknown VAD"),
    };
    let frame_size = detector.frame_samples();
    let mut vad = SmoothedVad::new(detector,
        frames_for_duration_ms(VAD_PREFILL_MS, frame_size),
        frames_for_duration_ms(VAD_STREAMING_HANGOVER_MS, frame_size),
        frames_for_duration_ms(VAD_ONSET_MS, frame_size));
    let model = Model::load(&args[1])?;
    let mut session = model.session()?;
    let run = RunOptions::default();
    // Same model API and defaults as Handy's run_stream_worker; no text cleanup.
    let mut stream = session.stream(&run, &StreamOptions::default())?;
    let start = Instant::now();
    let mut events = Vec::new();
    let mut forwarded = 0;
    for (index, chunk) in pcm.chunks(frame_size).enumerate() {
        let deadline = Duration::from_secs_f64(((index * frame_size + chunk.len()) as f64) / 16000.0);
        if let Some(wait) = deadline.checked_sub(start.elapsed()) { std::thread::sleep(wait); }
        let mut padded = vec![0.0; frame_size];
        padded[..chunk.len()].copy_from_slice(chunk);
        let selected = if args[5] == "off" { VadFrame::Speech(chunk) } else { vad.push_frame(&padded)? };
        if let VadFrame::Speech(samples) = selected {
            forwarded += samples.len();
            let update = stream.feed(samples)?;
            if update.committed_changed || update.tentative_changed {
                let text = stream.text();
                events.push(json!({"elapsed_ms":start.elapsed().as_secs_f64()*1000.0,
                    "audio_ms": (index * frame_size + chunk.len()) as f64 / 16.0,
                    "committed":text.committed,"tentative":text.tentative}));
            }
        }
    }
    let stop_ms = start.elapsed().as_secs_f64()*1000.0;
    stream.finalize()?;
    let output = json!({"status":"ok", "text":stream.text().full, "events":events,
        "stop_ms":stop_ms,"elapsed_ms":start.elapsed().as_secs_f64()*1000.0,
        "forwarded_audio_ms":forwarded as f64 / 16.0,
        "handy_commit":"bc7facea3a777869182203cfcf5c90f7a98efd99",
        "transcribe_cpp":"0.2.0", "vad":args[5], "model":args[1],
        "mode":"streaming", "cleanup":false});
    fs::write(&args[3], serde_json::to_vec_pretty(&output)?)?;
    Ok(())
}
