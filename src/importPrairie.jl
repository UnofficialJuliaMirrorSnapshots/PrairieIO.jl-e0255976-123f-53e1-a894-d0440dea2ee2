### TODO : zseries linescans-pointscans support. Voltage stim and recording import.

### Reads a Prairie xml file and extracts the useful metadata.
function importPrairie(xmlFile)
    scanConfigDoc = root(parse_file(xmlFile))
    baseDir = dirname(xmlFile)
    
    prairieRelease = attribute(scanConfigDoc,"version")

    expDate = attribute(scanConfigDoc,"date")
 
   ### Reading the file per repeat
    runElements = get_elements_by_tagname(scanConfigDoc,"Sequence")
    seqParameters = [dictSequenceParameters(runE) for runE=runElements]

    ### Getting frame related information
    frames= Array{Dict}(length(seqParameters))
    for i in 1:length(seqParameters)
        frame = get_elements_by_tagname(runElements[i],"Frame")
        files = [get_elements_by_tagname(fr,"File") for fr=frame]
        files = [[attributes_dict(f) for f=fi] for fi=files]
        timing = [Meta.parse(attribute(fr,"absoluteTime")) for fr=frame]
        frames[i] = Dict("timing" => timing,"File" => files)
    end
    
    laserParameters = parseLaserConfiguration(scanConfigDoc)
    serieParameters = parseSerieParameters(scanConfigDoc,prairieRelease)
    
    ### Getting DAC related information
    dacParameters = [getDAC(runE,prairieRelease,baseDir) for runE=runElements]
        
    Dict("laser" => laserParameters,"globalConfig" => serieParameters,"sequences" => seqParameters,"version" => prairieRelease, "frames" => frames, "dataDir" => baseDir, "DAC" => dacParameters)
end


### Functions to access given elements of the xml doc ###########################
    ### Extract the laser settings (only useful if there's more than one laser being used)
    function parseLaserConfiguration(xmlPrairieDoc)
        systemConfigItem = find_element(xmlPrairieDoc,"SystemConfiguration")
        laserItem =  find_element(systemConfigItem,"Lasers")
        laserItems = get_elements_by_tagname(laserItem,"Laser")
        rigConfig = Dict("laser.$i" => attributes_dict(laserItems[i]) for i=1:length(laserItems))
    end
        
    ### Global PVStateShard configuration of the experiment
    function parseSerieParameters(xmlPrairieDoc,version,dictOut=true)
        version = Meta.parse(version[1:3])
          ### In Prairie 4, parameters are given for each frame, so we take the very first frame parameters for the  global ones (and just ignore if there's anything frame specific, like in ZSeries)
        if 4 <= version < 5
            params = find_element(find_element(find_element(xmlPrairieDoc,"Sequence"),"Frame"),"PVStateShard")
        elseif version >= 5
            params = find_element(xmlPrairieDoc,"PVStateShard")
        end
        if dictOut
            params = pvParameters2dict(params)
        end
        params 
    end    

   

### Functions parsing sequence elements        
    ### Sequence configuration and attributes
    function dictSequenceParameters(seqElement)
        ### In some cases (?) there are StateShard elements per sequence
        Dict("attributes" => attributes_dict(seqElement), "state" => pvParameters2dict(find_element(seqElement,"PVStateShard")))
    end    

  
### Other utilities        
### Creates a dict from an xml "PVStateShard" node
function pvParameters2dict(prairieConfNode)
    if  prairieConfNode == nothing
        return(false)
    elseif !has_children(prairieConfNode)
        return(false)
    else
    keyElement = get_elements_by_tagname(prairieConfNode,"Key")
    ### false is written False in the xml file (hence the lowercase), everything else is numeric except the magnification that has an "x" written next to it (so we remove it to get the objective mag as a number).
    params = Dict(attribute(keyElement[i],"key") => Meta.parse(replace(lowercase(attribute(keyElement[i],"value")),"x","")) for i=1:length(keyElement))
    return params
    end    
end

### Functions reading the output of an import    
### Return image frames of a given sequence
    
function getPrairieFrames(prairieImport;seqN=1,channel=2,frameN="All")
        
    if frameN=="All"
        frames = prairieImport["frames"][seqN]["File"]
    else
        frames = prairieImport["frames"][seqN]["File"][[frameN]]
    end
    
    channels = [Meta.parse(fr["channel"]) for fr=frames[1]]    
    whichFile = findfirst(channels,channel)
    filenames = [joinpath(prairieImport["dataDir"],fX[whichFile]["filename"]) for fX=frames]
    seqParams = prairieImport["globalConfig"]
    
    width = seqParams["pixelsPerLine"]
    height = seqParams["linesPerFrame"]
    
    im = pmap(load,filenames)
    #im = reinterpret(Normed{UInt16,16},cat(3,im...))
    im = reinterpret(N4f12,cat(3,im...))  ## Output from Prairie is 12 bits, in a 16 bits file.
    #protocolType = prairieImport["sequences"][seqN]["attributes"]["type"]

    xStep = seqParams["micronsPerPixel_XAxis"]
    yStep = seqParams["micronsPerPixel_YAxis"]
    timeStep = seqParams["framePeriod"]*seqParams["rastersPerFrame"]

    im = AxisArray(im,Axis{:x}(xStep*(1/2:size(im,1))),Axis{:y}(yStep*(1/2:size(im,2))),Axis{:time}(timeStep*(0:(size(im,3)-1))))
    #im["timedim"] = 3
    #im["spatialorder"]=["x","y"]
    #im["pixelspacing"] = [seqParams["micronsPerPixel_XAxis"],seqParams["micronsPerPixel_YAxis"],seqParams["framePeriod"]*seqParams["rastersPerFrame"]]
    #im["period"]=seqParams["framePeriod"]*seqParams["rastersPerFrame"]
    im
end

function getDAC(seqItem,version,baseDir)
    version = Meta.parse(version[1:3])
    if version>=5
        if find_element(seqItem,"VoltageOutput")!=nothing
            vOut = get_elements_by_tagname(seqItem,"VoltageOutput")
            voltOutPath = attribute(vOut[1],"filename")
            voltOutPath = "$(baseDir)/$(voltOutPath)"
            voutXml = root(parse_file(voltOutPath))
            voutCh = get_elements_by_tagname(voutXml,"Waveform")
            output = findall(map((x) -> content(get_elements_by_tagname(x,"Enabled")[1])=="true",voutCh))
           
            outList = map(voutCh[output]) do dac
          
            #dacList <- xmlToList(dac)
        #    dacList <- dacList[-which(grepl("text",names(dacList)) | grepl("PlotColor",names(dacList)))]
                pulseTrain = get_elements_by_tagname(dac,"WaveformComponent_PulseTrain")
                stimDict = Dict{String,Any}()
                for e in child_elements(pulseTrain[1])
                    val = Meta.parse(replace(content(e)," ",""))
                    if typeof(val) == Symbol
                        val = string(val)
                    end
                    stimDict[name(e)] = val
                end

                dacDict = Dict{String,Any}()
                for d in child_elements(dac)
                    if "PlotColor" != name(d) != "WaveformComponent_PulseTrain"
                        val = Meta.parse(replace(content(d)," ",""))
                        if typeof(val) == Symbol
                            val = string(val)
                        end
                        dacDict[name(d)] = val
                    end
                end
            
                dacDict["triggerMode"] = attribute(vOut[1],"triggerMode")
                dacDict["relativeTime"] = Meta.parse(attribute(vOut[1],"relativeTime"))
                dacDict["absoluteTime"] = Meta.parse(attribute(vOut[1],"absoluteTime"))
                Dict("DACDeviceParameters"=>dacDict, "DACStimulusParameters"=>stimDict)
            end
        else
            nothing     
        end
    elseif 4<=version<5
       ##TO DO, for now just return the prm file
        [joinpath(baseDir,filter(x->contains(x,".prm"), readdir(baseDir))[1])]
    end
    
end


        
