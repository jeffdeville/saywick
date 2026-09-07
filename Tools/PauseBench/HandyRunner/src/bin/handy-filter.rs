use anyhow::{bail, Result};
use std::{env, fs};
use serde_json::json;
include!(concat!(env!("OUT_DIR"), "/handy_audio.rs"));
use audio_toolkit::vad::*;
fn main() -> Result<()> {
    let args: Vec<_> = env::args().collect();
    if args.len()!=4 { bail!("Usage: handy-filter INPUT_WAV OUTPUT_JSON SILERO_MODEL"); }
    let mut reader=hound::WavReader::open(&args[1])?;
    let spec=reader.spec();
    if spec.sample_rate!=16000 || spec.channels!=1 || spec.bits_per_sample!=16 || spec.sample_format!=hound::SampleFormat::Int { bail!("Expected PCM16 mono 16kHz"); }
    let pcm:Vec<i16>=reader.samples::<i16>().collect::<Result<_,_>>()?;
    let detector=Box::new(SileroVad::new(&args[3],0.3)?);
    let size=detector.frame_samples();
    let mut vad=SmoothedVad::new(detector,frames_for_duration_ms(VAD_PREFILL_MS,size),frames_for_duration_ms(VAD_STREAMING_HANGOVER_MS,size),frames_for_duration_ms(VAD_ONSET_MS,size));
    let mut frames=Vec::new();
    let mut forwarded=0;
    for (i,chunk) in pcm.chunks(size).enumerate() {
        let mut input=vec![0.0;size];
        for (a,b) in input.iter_mut().zip(chunk) {*a=*b as f32/32768.0;}
        if let VadFrame::Speech(samples)=vad.push_frame(&input)? {
            let output:Vec<i16>=samples.iter().map(|s|(s*32768.0).round().clamp(-32768.0,32767.0) as i16).collect();
            forwarded+=output.len();
            frames.push(json!({"at_ms":(i*size+chunk.len()) as f64/16.0,"samples":output}));
        }
    }
    fs::write(&args[2],serde_json::to_vec(&json!({"source_samples":pcm.len(),"forwarded_samples":forwarded,"frames":frames,"handy_commit":"bc7facea3a777869182203cfcf5c90f7a98efd99"}))?)?;
    Ok(())
}
