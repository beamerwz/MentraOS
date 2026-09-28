import {useEffect, useState} from "react"
import {ActivityIndicator, Pressable, ScrollView, Text as RNText, View} from "react-native"
import * as DocumentPicker from "expo-document-picker"
import RNFS from "@dr.pogodin/react-native-fs"
import {router} from "expo-router"

import {Screen} from "@/components/ignite"
import {sttModelManager as STT} from "@mentra/engine-host-internal"

type Metrics = {firstPartial: string; partialInterval: string; changedRate: string; decodeRtf: string; backlog: string; sttToG2: string}

const emptyMetrics: Metrics = {firstPartial:"—",partialInterval:"—",changedRate:"—",decodeRtf:"—",backlog:"—",sttToG2:"—"}

export default function G2ModelLab() {
  const [current,setCurrent]=useState(STT.getCurrentLanguage())
  const [busy,setBusy]=useState<string|null>(null)
  const [progress,setProgress]=useState(0)
  const [metrics]=useState<Metrics>(emptyMetrics)
  const [status,setStatus]=useState("Ready")

  useEffect(()=>{ void STT.getCurrentLanguageFromPreferences().then(v=>v&&setCurrent(v)) },[])

  const activate=async(code:string)=>{
    try{
      setBusy(code); setStatus("Preparing model…")
      const info=await STT.getLanguageInfo(code)
      if(!info.downloaded){
        await STT.downloadModel(code,p=>setProgress(p.percentage))
      }
      await STT.activateLanguage(code)
      setCurrent(code); setStatus("Active")
    }catch(e:any){setStatus(e?.message??"Model activation failed")}finally{setBusy(null);setProgress(0)}
  }

  const importCustom=async()=>{
    try{
      const picked=await DocumentPicker.getDocumentAsync({type:"application/x-bzip2",copyToCacheDirectory:true})
      if(picked.canceled) return
      const asset=picked.assets[0]
      setBusy("custom"); setStatus("Importing + validating custom model…")
      const temp=`${RNFS.TemporaryDirectoryPath}/g2labs-custom-model.tar.bz2`
      if(await RNFS.exists(temp)) await RNFS.unlink(temp)
      const source=decodeURIComponent(asset.uri.replace("file://",""))
      await RNFS.copyFile(source,temp)
      await STT.importCustomArchive(temp,"it-IT")
      setCurrent("custom"); setStatus(`Custom active · ${asset.name}`)
      await RNFS.unlink(temp).catch(()=>undefined)
    }catch(e:any){setStatus(e?.message??"Custom import failed")}finally{setBusy(null)}
  }

  const Card=({code,title,sub}:{code:string,title:string,sub:string})=>(
    <Pressable onPress={()=>void activate(code)} disabled={!!busy}
      style={{backgroundColor:"#15111d",borderWidth:1,borderColor:current===code?"#9b5cff":"#30263d",borderRadius:18,padding:16,marginBottom:12}}>
      <RNText style={{color:"white",fontSize:17,fontWeight:"700"}}>{title}</RNText>
      <RNText style={{color:"#a99db8",marginTop:4}}>{sub}</RNText>
      <RNText style={{color:current===code?"#b989ff":"#766985",marginTop:8,fontWeight:"600"}}>
        {busy===code?`Preparing… ${progress}%`:current===code?"● ACTIVE":"Tap to download / activate"}
      </RNText>
    </Pressable>
  )

  return <Screen preset="fixed" style={{backgroundColor:"#09070d"}}>
    <ScrollView contentContainerStyle={{padding:22,paddingTop:60,paddingBottom:60}}>
      <Pressable onPress={()=>router.back()}><RNText style={{color:"#b989ff",fontSize:16}}>‹ Back</RNText></Pressable>
      <RNText style={{color:"white",fontSize:32,fontWeight:"800",marginTop:18}}>G2 MODEL LAB</RNText>
      <RNText style={{color:"#9b8cae",fontSize:15,marginTop:6,marginBottom:24}}>Live speech-engine lab · Italian</RNText>

      <Card code="it" title="Italian Built-in" sub="Known-good Kroko INT8 · recovery baseline" />
      <Card code="nemotron_it_80" title="Nemotron 3.5 · 80 ms ⚡ ULTRA" sub="Lowest-latency multilingual streaming preset" />
      <Card code="nemotron_it_160" title="Nemotron 3.5 · 160 ms ⚡ FAST" sub="Latency / accuracy balance" />

      <Pressable onPress={()=>void importCustom()} disabled={!!busy}
        style={{backgroundColor:"#211332",borderWidth:1,borderColor:"#9b5cff",borderRadius:18,padding:16,marginTop:4}}>
        <RNText style={{color:"white",fontSize:17,fontWeight:"800"}}>＋ Import Custom Sherpa Model</RNText>
        <RNText style={{color:"#bda8d6",marginTop:5}}>.tar.bz2 · transducer or CTC · validated before activation</RNText>
      </Pressable>

      {busy && <ActivityIndicator style={{marginTop:18}} color="#b989ff"/>}
      <RNText style={{color:"#b989ff",marginTop:14}}>{status}</RNText>

      <View style={{backgroundColor:"#100d16",borderRadius:18,padding:18,marginTop:28,borderWidth:1,borderColor:"#292032"}}>
        <RNText style={{color:"white",fontSize:20,fontWeight:"800",marginBottom:14}}>LIVE BENCHMARK</RNText>
        {[
          ["First partial",metrics.firstPartial+" ms"],["Partial interval",metrics.partialInterval+" ms"],
          ["Changed partials/sec",metrics.changedRate],["Decode RTF",metrics.decodeRtf],
          ["Audio backlog",metrics.backlog+" ms"],["STT → G2",metrics.sttToG2+" ms"],
        ].map(([k,v])=><View key={k} style={{flexDirection:"row",justifyContent:"space-between",paddingVertical:7}}>
          <RNText style={{color:"#a99db8"}}>{k}</RNText><RNText style={{color:"white",fontWeight:"700"}}>{v}</RNText>
        </View>)}
        <RNText style={{color:"#6f637c",fontSize:12,marginTop:10}}>Metrics populate from G2LAB_TRACE during a live caption session.</RNText>
      </View>
    </ScrollView>
  </Screen>
}
