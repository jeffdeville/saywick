#!/usr/bin/env python3
"""Describe paired output differences; neither ASR nor LLM output is a human reference."""
import hashlib,json,pathlib,re,sys
from bench import alignment,tokens

def report(root):
    root=pathlib.Path(root)
    history=json.loads((root/'history.json').read_text())
    original=history['handy_before'];clean=history['handy_after']
    variants={'Handy saved before LLM':original,'Handy saved after LLM':clean}
    paths={'Parakeet fresh raw replay':'parakeet-replay.json','MAI streaming':'mai-stream.json',
           'MAI streaming, filter reapplied':'mai-stream-filtered.json','MAI whole-file verbatim':'mai-file-verbatim.json',
           'MAI whole-file clean':'mai-file-clean.json'}
    # Optional device replay of this same archived WAV; do not require an iPhone
    # for the existing cloud/desktop comparison workflow.
    if (root/'parakeet-ios.json').exists():
        paths['Parakeet on iPhone, raw CPU stream']='parakeet-ios.json'
    statuses={}
    for name,file in paths.items():
        if not (root/file).exists():statuses[name]='pending';continue
        result=json.loads((root/file).read_text());statuses[name]=result['status']
        if result['status']=='ok':variants[name]=result['text']
        else:statuses[name]+=': '+result.get('error','unknown')
    _,matched=alignment(original,clean);a,b=tokens(original),tokens(clean);boundaries=[]
    for i,j in sorted(matched.items()):
        if i==0 or i-1 not in matched or matched[i-1]!=j-1:continue
        before=original[a[i-1].end():a[i].start()];after=clean[b[j-1].end():b[j].start()]
        if re.search(r'[.!?]',before) and not re.search(r'[.!?]',after) and a[i].group()[0].isupper() and b[j].group()[0].islower():boundaries.append(i)
    lines=['# Natural recording comparison','',
           'One archived 312.36-second recording, selected because its saved LLM pass changed three sentence boundaries. This selection is not a representative quality benchmark.',
           '', 'Audio was already filtered by Handy before saving. Saved pre-LLM text may already include vocabulary/filler/stutter processing; the fresh Parakeet replay disables those text transforms. The historical model revision was not recorded.',
           '', 'No human reference was created. Word edits below measure disagreement with the saved pre-LLM text, not recognition error rate.', '',
           '| Path | Words | Word edits vs saved pre-LLM | Terminal punctuation, excluding ellipses |', '|---|---:|---:|---:|']
    for name,text in variants.items():
        edits,_=alignment(original,text)
        lines.append(f'| {name} | {len(tokens(text))} | {edits} | {len(re.findall(r"(?<!\.)\.(?!\.)|[!?]",text))} |')
    for name,status in statuses.items():
        if status!='ok':lines+=['',f'{name}: {status}']
    lines+=['','## The three boundaries changed by Handy’s saved LLM pass','',
            'These are formatting choices observed in the saved pair, not automatically labelled mistakes.','']
    timestamp_words=[]
    batch_path=root/'mai-file-verbatim.json'
    if batch_path.exists():
        for phrase in json.loads(batch_path.read_text()).get('response',{}).get('phrases',[]):
            for word in phrase.get('words',[]):
                for token in tokens(word['text']): timestamp_words.append(dict(word,token=token.group()))
    _,time_mapping=alignment(original,' '.join(w['token'] for w in timestamp_words))
    observations=[]
    for i in boundaries:
        context=original[a[max(0,i-5)].start():a[min(len(a)-1,i+5)].end()]
        lines += ['### '+context,'','| Path | Aligned excerpt |','|---|---|']
        detail={'source_word_index':i,'context':context,'variants':{}}
        if i in time_mapping and i-1 in time_mapping and time_mapping[i]==time_mapping[i-1]+1:
            left,right=timestamp_words[time_mapping[i-1]],timestamp_words[time_mapping[i]]
            detail['estimated_gap_ms']=right['offsetMilliseconds']-left['offsetMilliseconds']-left['durationMilliseconds']
        for name,text in variants.items():
            _,mapping=alignment(original,text);t=tokens(text)
            if i not in mapping or i-1 not in mapping or mapping[i]!=mapping[i-1]+1:
                excerpt='Changed wording; no adjacent exact alignment'
            else:
                j=mapping[i];excerpt=text[t[max(0,j-4)].start():t[min(len(t)-1,j+5)].end()]
            detail['variants'][name]=excerpt
            lines.append(f'| {name} | {excerpt.replace(chr(10)," ").replace("|","/")} |')
        observations.append(detail);lines.append('')
        if 'estimated_gap_ms' in detail:
            lines += [f"Estimated gap from MAI word timestamps: {detail['estimated_gap_ms']} ms (not human-verified).", '']
    lines += ['## Interpretation limits','',
              '- MAI streaming exposes the mai-transcribe alias; the whole-file request pins MAI-Transcribe-2. Any difference can reflect both inference mode and backend revision.',
              '- Reapplying the filter cannot recover silence removed before the archived file was saved. This is not an unfiltered-versus-filtered microphone experiment.',
              '- The whole-file clean variant controls for service-side formatting separately from the verbatim variant.',
              '- Full texts below are private local artifacts; no additional LLM was called for this comparison.','']
    for name,text in variants.items():lines+=['## '+name,'',text,'']
    (root/'report.md').write_text('\n'.join(lines))
    (root/'boundary-comparison.json').write_text(json.dumps(observations,indent=2))
    print('Available paths',len(variants),'of',len(paths)+2,'; report:',root/'report.md')

if __name__=='__main__':report(sys.argv[1])
