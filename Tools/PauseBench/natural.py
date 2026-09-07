#!/usr/bin/env python3
"""Compare an archived Handy utterance without treating either transcript as ground truth."""
import base64, concurrent.futures, hashlib, json, os, pathlib, re, struct, subprocess, sys, time, urllib.request, urllib.error, uuid
from bench import read_wav, alignment, tokens
ROOT=pathlib.Path(__file__).resolve().parents[2]

def main():
    output=pathlib.Path(sys.argv[1]).resolve()
    history=json.loads((output/'history.json').read_text())
    source=pathlib.Path.home()/'Library/Application Support/com.pais.handy/recordings'/history['file_name']
    pcm=read_wav(source);(output/'source.pcm').write_bytes(pcm)
    filtered=json.loads((output/'filter.json').read_text())
    packets=[]
    covered_end=0; unique_samples=0
    for frame in filtered['frames']:
        end=round(frame['at_ms']*16); start=end-len(frame['samples'])
        unique_samples+=max(0,end-max(covered_end,start)); covered_end=max(covered_end,end)
        data=struct.pack('<'+'h'*len(frame['samples']),*frame['samples'])
        packets.append(dict(at_ms=frame['at_ms'],audio=base64.b64encode(data).decode()))
    (output/'schedule.json').write_text(json.dumps(packets))
    key=os.environ['AZURE_SPEECH_KEY'];endpoint=os.environ['AZURE_SPEECH_ENDPOINT'].rstrip('/')
    if not re.fullmatch(r'https://[A-Za-z0-9-]+\.cognitiveservices\.azure\.com',endpoint):
        raise SystemExit('Invalid Azure resource endpoint')
    def save(name,result):
        encoded=json.dumps(result,indent=2).replace(key,'[redacted]')
        (output/(name+'.json')).write_text(encoded)
        print(name,result['status'],flush=True)
        return result
    def stream(name,filter_audio):
        destination=output/(name+'.json')
        destination.unlink(missing_ok=True)
        command=[str(ROOT/'.build/PauseTests/debug/pause-bench-azure'),'server1500',str(output/'source.pcm'),str(destination)]
        if filter_audio:command.append(str(output/'schedule.json'))
        start=time.monotonic()
        try:
            run=subprocess.run(command,capture_output=True,text=True,timeout=len(pcm)/32000+100)
            result=json.loads(destination.read_text()) if destination.exists() else dict(status='error',error=run.stderr[-2000:])
            if run.returncode:result['status']='error'
            result['duration_seconds']=time.monotonic()-start
        except Exception as e:result=dict(status='error',error=str(e))
        return save(name,result)
    def batch(style):
        definition={'enhancedMode':{'enabled':True,'model':'MAI-Transcribe-2','modelOptions':{'transcribeStyle':style,'timestamps':'word'}},'diarization':{'enabled':False}}
        boundary='PauseBench-'+uuid.uuid4().hex
        body=(f'--{boundary}\r\nContent-Disposition: form-data; name="definition"\r\nContent-Type: application/json\r\n\r\n'+json.dumps(definition)+'\r\n'+f'--{boundary}\r\nContent-Disposition: form-data; name="audio"; filename="dictation.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode()+source.read_bytes()+f'\r\n--{boundary}--\r\n'.encode()
        request=urllib.request.Request(endpoint+'/speechtotext/transcriptions:transcribe?api-version=2025-10-15',data=body,headers={'Ocp-Apim-Subscription-Key':key,'Content-Type':'multipart/form-data; boundary='+boundary})
        start=time.monotonic()
        try:
            with urllib.request.urlopen(request,timeout=180) as response:data=json.load(response)
            text='\n'.join(p['text'] for p in data['combinedPhrases']).strip()
            result=dict(status='ok' if text else 'error',text=text,response=data,definition=definition,duration_seconds=time.monotonic()-start)
        except Exception as e:result=dict(status='error',error=str(e),definition=definition)
        return save('mai-file-'+style,result)
    metadata=dict(history_id=history['id'],source_audio_sha256=hashlib.sha256(pcm).hexdigest(),seconds=len(pcm)/32000,
                  additional_filter_net_duration_change_seconds=(filtered['forwarded_samples']-len(pcm)//2)/16000,
                  source_already_vad_filtered=True,
                  unique_samples_dropped_seconds=(len(pcm)//2-unique_samples)/16000,
                  repeated_preroll_seconds=(filtered['forwarded_samples']-unique_samples)/16000,
                  streaming_model='mai-transcribe (service alias; underlying revision not exposed)',batch_model='MAI-Transcribe-2',
                  runner_sha256=hashlib.sha256((ROOT/'.build/PauseTests/debug/pause-bench-azure').read_bytes()).hexdigest())
    (output/'experiment.json').write_text(json.dumps(metadata,indent=2))
    print('Starting natural comparison:',round(metadata['seconds'],1),'seconds; filter net duration change',round(metadata['additional_filter_net_duration_change_seconds'],2),'seconds',flush=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        futures=[pool.submit(stream,'mai-stream',False),pool.submit(stream,'mai-stream-filtered',True),pool.submit(batch,'verbatim'),pool.submit(batch,'clean')]
        results=[f.result() for f in futures]
    if any(r['status']!='ok' for r in results):raise SystemExit('Some natural comparison paths failed; inspect result files')
    print('Natural comparison complete',flush=True)

if __name__=='__main__':main()
