use std::{env, fs, path::PathBuf, process::Command};
fn main() {
    println!("cargo:rerun-if-env-changed=HANDY_SOURCE");
    let root = PathBuf::from(env::var("HANDY_SOURCE").expect("Set HANDY_SOURCE to pinned Handy checkout"))
        .canonicalize().unwrap();
    let commit = Command::new("git").args(["rev-parse", "HEAD"]).current_dir(&root).output().unwrap();
    assert_eq!(String::from_utf8_lossy(&commit.stdout).trim(), "bc7facea3a777869182203cfcf5c90f7a98efd99", "Wrong Handy revision");
    let base = root.join("src-tauri/src/audio_toolkit");
    for file in ["constants.rs", "vad/mod.rs", "vad/smoothed.rs", "vad/silero.rs", "vad/earshot.rs"] {
        let path = base.join(file);
        println!("cargo:rerun-if-changed={}", path.display());
        let diff = Command::new("git").args(["diff", "HEAD", "--", path.to_str().unwrap()]).current_dir(&root).output().unwrap();
        assert!(diff.status.success() && diff.stdout.is_empty(), "Handy audio source has modifications");
    }
    fs::write(PathBuf::from(env::var("OUT_DIR").unwrap()).join("handy_audio.rs"), format!(
        "pub mod audio_toolkit {{ #[path = {:?}] pub mod constants; #[path = {:?}] pub mod vad; }}",
        base.join("constants.rs"), base.join("vad/mod.rs"))).unwrap();
}
