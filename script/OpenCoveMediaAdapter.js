// SPDX-License-Identifier: MIT
// Independent MediaRemote bridge. Foundation only; no Apple Events or app UI.
ObjC.import('Foundation');
$.NSBundle.bundleWithPath('/System/Library/PrivateFrameworks/MediaRemote.framework').load;
ObjC.bindFunction('getppid', ['int', []]);
ObjC.bindFunction('exit', ['void', ['int']]);
function run(argv) {
    const action = argv[0] || '--read';
    const watch = action === '--watch';
    const actions = ['--read','--watch','--toggle','--next','--previous','--seek','--rate'];
    const api = $.NSClassFromString('MRNowPlayingRequest');
    const out = $.NSFileHandle.fileHandleWithStandardOutput;
    let previous = '', emitted = -1e9, artworkKey = '', artworkData = null, artworkAttempt = -1e9, sentArtworkKey = '';
    function now() { return Number($.NSProcessInfo.processInfo.systemUptime); }
    function text(value) { try { const s=ObjC.unwrap(value); return typeof s === 'string' ? s : ''; } catch (_) { return ''; } }
    // KVC forces a fresh native getter. JXA property proxies can retain a prior value.
    function get(object, selector) { try { return object.valueForKey(selector); } catch (_) { return null; } }
    function present(value) { try { return value !== null && value !== undefined && !value.isNil(); } catch(_) { return false; } }
    function field(info, key) { try { return info.objectForKey(key); } catch (_) { return null; } }
    function id(info) { const value=text(field(info,'kMRMediaRemoteNowPlayingInfoContentItemIdentifier')); return value && value.length <= 8192 ? value : ''; }
    function bundle() { return text(get(get(get(api,'localNowPlayingPlayerPath'),'client'),'bundleIdentifier')); }
    function currentInfo() { return get(get(api,'localNowPlayingItem'),'nowPlayingInfo'); }
    function emit(value) {
        // Send cover bytes only when their source/item/version changes. The
        // parent merges this bounded delta before coalescing UI deliveries.
        if(watch) {
            const info=field(value,'info');
            if(present(info) && id(info)) {
                const key=text(field(value,'bundleID'))+'\n'+id(info)+'\n'+text(field(info,'kMRMediaRemoteNowPlayingInfoArtworkIdentifier'));
                // The parent drops its image when this context changes, even
                // if the next item has no cover. Returning must resend bytes.
                if(key!==sentArtworkKey) sentArtworkKey='';
                if(present(field(info,'kMRMediaRemoteNowPlayingInfoArtworkData'))) {
                    if(key===sentArtworkKey) info.removeObjectForKey('kMRMediaRemoteNowPlayingInfoArtworkData');
                    else sentArtworkKey=key;
                }
            } else sentArtworkKey='';
        }
        const error = Ref();
        const data = $.NSPropertyListSerialization.dataWithPropertyListFormatOptionsError(value, $.NSPropertyListBinaryFormat_v1_0, 0, error);
        if (!data || Number(data.length) > 16*1024*1024) $.exit(1);
        const encoded = text(data.base64EncodedStringWithOptions(0));
        if (watch && encoded === previous && now()-emitted < 15) return;
        previous=encoded; emitted=now();
        out.writeData($(JSON.stringify({snapshot:encoded})+'\n').dataUsingEncoding($.NSUTF8StringEncoding));
    }
    function dict(values) { return $.NSMutableDictionary.dictionaryWithDictionary(values); }
    function fail(message) { emit(dict({error:message})); $.exit(1); }
    if (!actions.includes(action) || argv.length > 6) fail('Unsupported media adapter action.');
    const seek=action==='--seek', rate=action==='--rate', itemCommand=seek||rate, command=!watch && action!=='--read';
    if (command && (argv[itemCommand?2:1]!=='--source' || !argv[itemCommand?3:2] || argv.length!==(itemCommand?6:3))) fail('A media source is required.');
    if (!command && argv.length>1) fail('The metadata reader takes no extra arguments.');
    if (itemCommand && (!/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/.test(argv[1]) || argv[4]!=='--item' || !argv[5] || argv[5].length>8192 || !Number.isFinite(Number(argv[1])) || Number(argv[1])<0)) fail('A finite value and item identifier are required.');
    if (rate && (Number(argv[1])<=0 || Number(argv[1])>16)) fail('The playback rate is outside the supported range.');
    function supported() {
        const result=$.NSMutableArray.alloc.init;
        const list=get(api,'localSupportedCommands');
        if (list) for(let i=0;i<Number(list.count);i++) {
            const value=get(list.objectAtIndex(i),'dictionaryRepresentation');
            if(value) result.addObject(value);
        }
        return result;
    }
    function enabled(list,name) {
        for(let i=0;i<Number(list.count);i++) {
            const value=list.objectAtIndex(i);
            if(text(field(value,'command'))!==name) continue;
            const flag=field(value,'enabled');
            try { if(Number(flag.boolValue)) return true; } catch(_) {}
            if(text(flag).toUpperCase()==='YES') return true;
        }
        return false;
    }
    function playbackRates(list) {
        for(let i=0;i<Number(list.count);i++) {
            const value=list.objectAtIndex(i);
            if(text(field(value,'command'))!=='ChangePlaybackRateCommand' || !enabled($.NSArray.arrayWithObject(value),'ChangePlaybackRateCommand')) continue;
            const rates=field(field(value,'options'),'kMRMediaRemoteCommandInfoSupportedPlaybackRates');
            if(!present(rates) || Number(rates.count)>32) return [];
            const result=[];
            for(let j=0;j<Number(rates.count);j++) {
                const value=ObjC.unwrap(rates.objectAtIndex(j));
                if(typeof value==='number' && Number.isFinite(value) && value>0 && value<=16 && !result.includes(value)) result.push(value);
            }
            return result;
        }
        return [];
    }
    function waitUntil(predicate, seconds) {
        const deadline=now()+seconds;
        while(!predicate() && now()<deadline) $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(0.02));
    }
    // Finish the command burst once actual item or playback state changes.
    function signal(payload) {
        const info=field(payload,'info');
        let rate='';
        try {
            const value=ObjC.unwrap(field(info,'kMRMediaRemoteNowPlayingInfoPlaybackRate'));
            if(typeof value==='number' && Number.isFinite(value)) rate=String(value);
        } catch(_) {}
        return text(field(payload,'bundleID'))+'\n'+id(info)+'\n'+rate;
    }
    function snapshot() {
        const source=bundle(), info=currentInfo(), commands=supported();
        const payload=dict({version:1,canValidateSeekItem:false});
        payload.setObjectForKey(commands,'commands');
        if(source) payload.setObjectForKey(source,'bundleID');
        if(!source || !present(info) || Number(info.count)===0) {
            payload.setObjectForKey('MediaRemote returned no metadata for this process.','error');
            return payload;
        }
        const item=id(info), version=text(field(info,'kMRMediaRemoteNowPlayingInfoArtworkIdentifier'));
        const key=source+'\n'+item+'\n'+version;
        const value=$.NSMutableDictionary.dictionaryWithDictionary(info);
        if(item && !present(field(info,'kMRMediaRemoteNowPlayingInfoArtworkData')) && (key!==artworkKey || (!artworkData && now()-artworkAttempt>=15))) {
            artworkKey=key;artworkData=null;artworkAttempt=now();
            let complete=false, accepted=true;
            try {
                const request=api.alloc.init;
                const callback=ObjC.block(['void',['id','id']],function(artwork,error) {
                    if(!accepted) return;
                    try {
                        const bytes=artwork.imageData;
                        const current=currentInfo();
                        if(!present(error) && present(bytes) && Number(bytes.length)>0 && Number(bytes.length)<=12*1024*1024 && bundle()===source && id(current)===item && text(field(current,'kMRMediaRemoteNowPlayingInfoArtworkIdentifier'))===version) artworkData=bytes;
                    } catch(_) {}
                    complete=true;
                });
                const lifetime=$.NSMutableDictionary.alloc.init;
                lifetime.setObjectForKey(callback,'callback');
                ObjC.bindFunction('objc_msgSend',['void',['id','SEL','id','id']]);
                $.objc_msgSend(request,$.NSSelectorFromString('requestNowPlayingItemArtworkOnQueue:completion:'),$.NSOperationQueue.mainQueue.underlyingQueue,lifetime.objectForKey('callback'));
                waitUntil(()=>complete,1.5);
            } catch(_) {}
            accepted=false;
        }
        if(key===artworkKey && artworkData) value.setObjectForKey(artworkData,'kMRMediaRemoteNowPlayingInfoArtworkData');
        if(bundle()!==source || (item && id(currentInfo())!==item)) return dict({error:'The current media source or item changed during the read.'});
        payload.setObjectForKey(value,'info');
        payload.setObjectForKey(Boolean(item && id(currentInfo())===item),'canValidateSeekItem');
        return payload;
    }
    if(command) {
        const source=argv[itemCommand?3:2], info=currentInfo(), commands=supported();
        if(bundle()!==source || !present(info) || Number(info.count)===0) fail('The selected media source is no longer active.');
        if(rate) {
            const selected=playbackRates(commands).find(value=>Math.abs(value-Number(argv[1]))<0.000001);
            if(selected===undefined) fail('This source does not advertise the selected playback rate.');
            // Capability and item validation are adjacent to submission. No
            // asynchronous artwork or metadata work can intervene here.
            if(id(info)!==argv[5] || id(currentInfo())!==argv[5] || bundle()!==source) fail('The current media item changed.');
            ObjC.bindFunction('MRMediaRemoteSendCommand',['bool',['int','id']]);
            if(!$.MRMediaRemoteSendCommand(19,dict({'kMRMediaRemoteOptionPlaybackRate':selected}))) fail('MediaRemote rejected the playback rate.');
        } else if(seek) {
            if(!enabled(commands,'SeekToPlaybackPosition')) fail('This source does not support seeking.');
            const current=currentInfo();
            const duration=Number(ObjC.unwrap(field(current,'kMRMediaRemoteNowPlayingInfoDuration')));
            if(id(info)!==argv[5] || id(current)!==argv[5] || bundle()!==source || !Number.isFinite(duration) || duration<=0) fail('The current item changed or cannot be identified.');
            ObjC.bindFunction('MRMediaRemoteSetElapsedTime',['void',['double']]);
            $.MRMediaRemoteSetElapsedTime(Math.min(Number(argv[1]),duration));
        } else {
            const name=action==='--toggle'?'TogglePlayPause':action==='--next'?'NextTrack':'PreviousTrack';
            const opcode=action==='--toggle'?2:action==='--next'?4:5;
            if(!enabled(commands,name) || bundle()!==source) fail('This source does not enable that media command.');
            ObjC.bindFunction('MRMediaRemoteSendCommand',['bool',['int','id']]);
            if(!$.MRMediaRemoteSendCommand(opcode,$.NSDictionary.dictionary)) fail('MediaRemote rejected the media command.');
        }
        emit(dict({submitted:true}));return;
    }
    if(!watch) { emit(snapshot());return; }
    const parent=$.getppid(), started=now();
    let dirty=true,sourceDirty=true,lastRead=-1e9,lastPeriodicRead=-1e9,hasMetadata=false,lastSource='';
    let requestDeadline=0,requestSignal='',lastSignal='';
    // Native notifications refresh MediaRemote's local cache. Do not install
    // reentrant JavaScript notification blocks; read the cache on the main loop.
    try {
        ObjC.bindFunction('MRMediaRemoteRegisterForNowPlayingNotifications',['void',['id']]);
        ObjC.bindFunction('dispatch_get_global_queue',['id',['long','unsigned long']]);
        $.MRMediaRemoteRegisterForNowPlayingNotifications($.dispatch_get_global_queue(0,0));
    } catch(_) {}
    // The parent can request a short, coalesced refresh after a command.
    // A native selector avoids reentrant JXA notification blocks. EOF simply
    // disables further requests; the normal cadence and lease still apply.
    const input=$.NSFileHandle.fileHandleWithStandardInput;
    ObjC.registerSubclass({name:'OpenCoveMediaRefreshInput',superclass:'NSObject',methods:{
        'inputReady:':{types:['void',['id']],implementation:function(notification) {
            const data=field(get(notification,'userInfo'),'NSFileHandleNotificationDataItem');
            if(!present(data) || Number(data.length)===0) return;
            if(now()>=requestDeadline) requestSignal=lastSignal;
            requestDeadline=now()+0.75;dirty=true;
            input.readInBackgroundAndNotify;
        }}
    }});
    const observer=$.OpenCoveMediaRefreshInput.alloc.init;
    $.NSNotificationCenter.defaultCenter.addObserverSelectorNameObject(observer,$.NSSelectorFromString('inputReady:'),'NSFileHandleReadCompletionNotification',input);
    input.readInBackgroundAndNotify;
    while($.getppid()===parent && now()-started<180) {
        const source=bundle();
        if(source!==lastSource) { dirty=true;sourceDirty=true;lastSource=source; }
        const interval=hasMetadata || source ? 1 : 15;
        const periodic=now()-lastPeriodicRead>=interval;
        if(((dirty || now()<requestDeadline) && now()-lastRead>=0.25) || periodic) {
            dirty=false;lastRead=now();
            // Early command reads must not postpone the ordinary poll.
            if(periodic || sourceDirty) lastPeriodicRead=lastRead;
            sourceDirty=false;
            const value=snapshot();
            hasMetadata=Boolean(present(field(value,'info')));lastSignal=signal(value);
            if(lastSignal!==requestSignal) requestDeadline=0;
            emit(value);
        }
        const deadline=dirty || now()<requestDeadline?Math.min(lastRead+0.25,lastPeriodicRead+interval):lastPeriodicRead+interval;
        const delay=Math.max(0.01,Math.min(1,deadline-now()));
        $.NSRunLoop.currentRunLoop.runModeBeforeDate($.NSDefaultRunLoopMode,$.NSDate.dateWithTimeIntervalSinceNow(delay));
    }
    $.NSNotificationCenter.defaultCenter.removeObserver(observer);
}
