require("hs.ipc")
-- Dettatura locale (al posto di Wispr Flow) e trascrittore delle call, con una pillola sul bordo destro.
--   Fn tenuto premuto: detta finché lo tieni; lasciandolo trascrive e incolla dove c'è il cursore.
--   Fn due volte di seguito: mani libere; un altro tocco di Fn finisce. Esc annulla.
--   Clic sulla pillola: inizia o finisce una dettatura.
--   Se un'app di call (Meet, Zoom, Teams, FaceTime, WhatsApp, ...) usa il microfono, la pillola chiede se trascrivere.
--   Col mouse sopra la linguetta: microfono = dettatura, pallino rosso sotto = registra una call.
--   Ctrl+Option+Cmd+R: avvia o ferma la registrazione di una call.
--   Ctrl+Option+Cmd+N o clic destro sulla pillola: apre il Notetaker.
-- Note: ~/.config/trascrittore/ (suoni in suoni/, registratore e comando `call`).
-- Impostazioni in ~/.config/trascrittore/dati/impostazioni.json (si cambiano dal Notetaker e valgono subito);
-- ogni dettatura passa dal dizionario (nt.cli) e finisce nello storico dati/dettature.jsonl.

local HOME = os.getenv("HOME")
local CARTELLA = HOME .. "/.config/trascrittore"
local MODELLO = HOME .. "/.cache/whisper-cpp/ggml-large-v3-turbo-q5_0.bin"
local PORTA = 8178
local FFMPEG = "/opt/homebrew/bin/ffmpeg"
local SERVER = "/opt/homebrew/bin/whisper-server"
local CURL = "/usr/bin/curl"
local CALL = CARTELLA .. "/call"
local TMP = os.getenv("TMPDIR")
local DATI = CARTELLA .. "/dati"
local PYTHON = CARTELLA .. "/venv/bin/python"
local NOTETAKER = HOME .. "/Applications/Notetaker.app"
local SPEGNI_DOPO = 15 * 60  -- secondi senza dettature prima di spegnere il server
local TIENI = 0.3            -- sotto: è un tocco; sopra: dettatura col tasto tenuto (il microfono parte subito comunque)
local DOPPIO = 0.7           -- tempo massimo tra l'inizio di due tocchi di Fn per le mani libere

D = {}                       -- globale, per le prove con `hs -c`
D.stato = "riposo"           -- riposo | sopra | ascolto | trascrivo | domanda | call
local server, timerSpegni, registrazione = nil, nil, nil
local maniLibere = false
local livello, barre, altezze = 0, {}, {}
local animazione, orologio, transizione = nil, nil, nil
local micDa, micIgnora, appCallAttuale = nil, false, nil
local callInizio, domandaScade = nil, nil
local fondoAttuale = { w = 10, h = 54 }
local inizioDettatura, appDettatura = nil, nil

---------------------------------------------------------------- impostazioni (dal Notetaker)
local PREDEFINITE = { tasto = "fn", suoni = true, volume = 0.45, microfono = "", domanda_call = true,
                      secondi_domanda = 6 }
local IMP = {}
local function caricaImpostazioni()
  local f = io.open(DATI .. "/impostazioni.json", "r")
  local letto = {}
  if f then
    local ok, v = pcall(hs.json.decode, f:read("a")); f:close()
    if ok and type(v) == "table" then letto = v end
  end
  for k, v in pairs(PREDEFINITE) do
    IMP[k] = (letto[k] ~= nil and type(letto[k]) == type(v)) and letto[k] or v
  end
  if IMP.tasto ~= "fn" and IMP.tasto ~= "option_destro" then IMP.tasto = "fn" end
  D.tasto = IMP.tasto
end
caricaImpostazioni()
D.IMP = IMP

-- Suggerimento iniziale per Whisper (frase d'esempio + termini del dizionario), rifatto quando cambia.
local promptWhisper = ""
local function aggiornaPrompt()
  hs.task.new(PYTHON, function(codice, out, _)
    if codice == 0 and out then promptWhisper = out:gsub("%s+$", "") end
  end, { "-m", "nt.cli", "prompt" }):setWorkingDirectory(CARTELLA):start()
end
aggiornaPrompt()
D.prompt = function() return promptWhisper end

---------------------------------------------------------------- timer
-- Un timer non tenuto in una variabile può essere eliminato da Hammerspoon prima di scattare:
-- dopo() e aspetta() lo tengono vivo finché non ha fatto il suo lavoro.
local VIVI = {}
local function dopo(secondi, fn)
  local t
  t = hs.timer.doAfter(secondi, function() VIVI[t] = nil; fn() end)
  VIVI[t] = true
  return t
end
local function aspetta(condizione, fn, passo)
  local t
  t = hs.timer.waitUntil(condizione, function() VIVI[t] = nil; fn() end, passo)
  VIVI[t] = true
  return t
end

---------------------------------------------------------------- suoni
local SUONI = {}
for _, n in ipairs({ "avvio", "stop", "blocco", "incolla", "annulla", "domanda" }) do
  SUONI[n] = hs.sound.getByFile(CARTELLA .. "/suoni/" .. n .. ".wav")
end
local function volumeSuoni()
  for _, s in pairs(SUONI) do s:volume(IMP.volume) end
end
volumeSuoni()
local function suona(n)
  local s = SUONI[n]
  if s and IMP.suoni then s:stop(); s:play() end
end

---------------------------------------------------------------- aspetto
local COL = {
  fondo  = { red = 0.07, green = 0.07, blue = 0.09, alpha = 0.95 },
  bordo  = { white = 1, alpha = 0.12 },
  testo  = { white = 1, alpha = 0.96 },
  tenue  = { white = 1, alpha = 0.55 },
  barra  = { red = 0.90, green = 0.92, blue = 1.0, alpha = 0.95 },
  rosso  = { red = 1.0, green = 0.30, blue = 0.30, alpha = 1 },
  blu    = { red = 0.35, green = 0.62, blue = 1.0, alpha = 1 },
  verde  = { red = 0.20, green = 0.76, blue = 0.46, alpha = 1 },
  grigio = { white = 1, alpha = 0.14 },
  lingua = { red = 0.10, green = 0.10, blue = 0.12, alpha = 0.72 },
}
local FONT = ".AppleSystemUIFont"
local FONTB = ".AppleSystemUIFontDemi"
local NBARRE = 13

local pillola = hs.canvas.new({ x = 0, y = 0, w = 10, h = 10 })
pillola:level(hs.canvas.windowLevels.overlay)
pillola:behavior({ "canJoinAllSpaces", "stationary" })
pillola:clickActivating(false) -- cliccarla non toglie il cursore dall'app in cui scrivi

local function cornice(w, h)
  local s = hs.screen.mainScreen():frame()
  return { x = s.x + s.w - w - 8, y = math.floor(s.y + s.h / 2 - h / 2), w = w, h = h }
end

local function fondo(w, h, colore)
  return { type = "rectangle", action = "strokeAndFill", fillColor = colore or COL.fondo,
           strokeColor = COL.bordo, strokeWidth = 1,
           roundedRectRadii = { xRadius = math.min(w, h) / 2, yRadius = math.min(w, h) / 2 },
           frame = { x = 0.5, y = 0.5, w = w - 1, h = h - 1 },
           trackMouseDown = true, trackMouseEnterExit = true, id = "fondo",
           shadow = { blurRadius = 8, color = { white = 0, alpha = 0.45 }, offset = { h = -2, w = 0 } },
           withShadow = true }
end

local function stile(size, colore, allinea, grassetto)
  return { font = { name = grassetto and FONTB or FONT, size = size }, color = colore,
           paragraphStyle = { alignment = allinea or "left" } }
end

local function testo(t, x, y, w, h, size, colore, id, allinea, grassetto)
  return { type = "text", text = hs.styledtext.new(t, stile(size, colore, allinea, grassetto)),
           frame = { x = x, y = y, w = w, h = h }, trackMouseDown = id ~= nil, id = id }
end

local function larghezzaTesto(t, size, grassetto)
  local d = hs.drawing.getTextDrawingSize(hs.styledtext.new(t, stile(size, COL.testo, "left", grassetto)))
  return math.ceil(d.w) + 4
end

-- Icona del microfono disegnata con le forme (centro cx, cy).
local function microfono(cx, cy, colore, scala)
  local k = scala or 1
  return {
    { type = "rectangle", action = "fill", fillColor = colore,
      roundedRectRadii = { xRadius = 3.5 * k, yRadius = 3.5 * k },
      frame = { x = cx - 3.5 * k, y = cy - 8 * k, w = 7 * k, h = 11 * k } },
    { type = "arc", action = "stroke", strokeColor = colore, strokeWidth = 1.6 * k,
      center = { x = cx, y = cy - 1 * k }, radius = 6 * k, startAngle = 90, endAngle = 270, arcRadii = false },
    { type = "rectangle", action = "fill", fillColor = colore,
      frame = { x = cx - 0.8 * k, y = cy + 5 * k, w = 1.6 * k, h = 3 * k } },
    { type = "rectangle", action = "fill", fillColor = colore,
      roundedRectRadii = { xRadius = 0.8 * k, yRadius = 0.8 * k },
      frame = { x = cx - 3.5 * k, y = cy + 7.4 * k, w = 7 * k, h = 1.6 * k } },
  }
end

local function aggiungi(el, lista)
  for _, e in ipairs(lista) do el[#el + 1] = e end
  return el
end

local function fermaAnimazioni()
  if animazione then animazione:stop(); animazione = nil end
  if orologio then orologio:stop(); orologio = nil end
end

-- Passaggio animato: lo sfondo si allarga o si stringe verso il bordo destro, poi compare il contenuto.
local function passa(w, h, colore, disegnaContenuto)
  if transizione then transizione:stop(); transizione = nil end
  local da = fondoAttuale
  local W, H = math.max(w, da.w), math.max(h, da.h)
  pillola:frame(cornice(W, H))
  pillola:replaceElements(fondo(da.w, da.h, colore))
  pillola:show()
  local t0 = hs.timer.secondsSinceEpoch()
  local durata = 0.16
  transizione = hs.timer.doEvery(1 / 60, function()
    local t = math.min(1, (hs.timer.secondsSinceEpoch() - t0) / durata)
    local e = 1 - (1 - t) ^ 3
    local bw = da.w + (w - da.w) * e
    local bh = da.h + (h - da.h) * e
    local r = math.min(bw, bh) / 2
    pillola[1].frame = { x = W - bw + 0.5, y = (H - bh) / 2 + 0.5, w = bw - 1, h = bh - 1 }
    pillola[1].roundedRectRadii = { xRadius = r, yRadius = r }
    if t >= 1 then
      transizione:stop(); transizione = nil
      fondoAttuale = { w = w, h = h }
      pillola:frame(cornice(w, h))
      disegnaContenuto()
    end
  end)
end

local disegna = {}

function disegna.riposo()
  passa(10, 54, COL.lingua, function()
    pillola:replaceElements(fondo(10, 54, COL.lingua),
      { type = "rectangle", action = "fill", fillColor = COL.tenue,
        roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 }, frame = { x = 3.5, y = 18, w = 3, h = 18 } })
  end)
end

function disegna.sopra()  -- il mouse è sopra la linguetta: microfono (dettatura) e, sotto, pallino rosso (call)
  local w, h = 34, 100
  passa(w, h, COL.fondo, function()
    local el = aggiungi({ fondo(w, h) }, microfono(17, 28, COL.testo, 1))
    aggiungi(el, {
      { type = "rectangle", action = "fill", fillColor = COL.grigio, frame = { x = 9, y = 51, w = 16, h = 1 } },
      { type = "circle", action = "stroke", strokeColor = COL.rosso, strokeWidth = 1.6,
        center = { x = 17, y = 74 }, radius = 8 },
      { type = "circle", action = "fill", fillColor = COL.rosso, center = { x = 17, y = 74 }, radius = 4.5 },
      -- zone di clic invisibili sopra le icone: metà alta dettatura, metà bassa call
      { type = "rectangle", action = "fill", fillColor = { white = 0, alpha = 0.01 },
        frame = { x = 0, y = 0, w = w, h = 51 }, trackMouseDown = true, id = "detta" },
      { type = "rectangle", action = "fill", fillColor = { white = 0, alpha = 0.01 },
        frame = { x = 0, y = 52, w = w, h = h - 52 }, trackMouseDown = true, id = "registraCall" },
    })
    pillola:replaceElements(table.unpack(el))
  end)
end

function disegna.ascolto()  -- linguetta verticale: onde orizzontali impilate che seguono la voce
  local w, h = 26, 108
  passa(w, h, COL.fondo, function()
    local el = { fondo(w, h),
      { type = "circle", action = "fill", fillColor = maniLibere and COL.blu or COL.rosso,
        center = { x = w / 2, y = 15 }, radius = 4, id = "punto" } }
    barre, altezze = {}, {}
    for i = 1, NBARRE do
      el[#el + 1] = { type = "rectangle", action = "fill", fillColor = COL.barra,
        roundedRectRadii = { xRadius = 1.25, yRadius = 1.25 },
        frame = { x = w / 2 - 1.5, y = 28 + (i - 1) * 6, w = 3, h = 2.5 } }
      barre[i], altezze[i] = #el, 3
    end
    pillola:replaceElements(table.unpack(el))
    local fase = 0
    animazione = hs.timer.doEvery(1 / 30, function()
      fase = fase + 0.28
      for i, idx in ipairs(barre) do
        local centro = 1 - math.abs(i - (NBARRE + 1) / 2) / (NBARRE / 2 + 1)
        local onda = 0.6 + 0.4 * math.sin(fase + i * 0.75)
        local meta = 3 + (w - 9) * livello * onda * (0.35 + 0.65 * centro)
        altezze[i] = altezze[i] + (math.min(w - 8, meta) - altezze[i]) * 0.35
        local a = altezze[i]
        pillola[idx].frame = { x = w / 2 - a / 2, y = 28 + (i - 1) * 6, w = a, h = 2.5 }
      end
      if maniLibere then  -- in mani libere il punto blu respira
        pillola[2].radius = 3.5 + 1.1 * (0.5 + 0.5 * math.sin(fase * 0.6))
      end
    end)
  end)
end

function disegna.trascrivo()  -- tre puntini in verticale che ondeggiano
  local w, h = 26, 64
  passa(w, h, COL.fondo, function()
    local el = { fondo(w, h) }
    for i = 1, 3 do
      el[#el + 1] = { type = "circle", action = "fill", fillColor = COL.testo,
        center = { x = w / 2, y = h / 2 + (i - 2) * 12 }, radius = 3 }
    end
    pillola:replaceElements(table.unpack(el))
    local fase = 0
    animazione = hs.timer.doEvery(1 / 30, function()
      fase = fase + 0.22
      for i = 1, 3 do
        local v = 0.5 + 0.5 * math.sin(fase - i * 0.9)
        pillola[i + 1].radius = 2.2 + 1.3 * v
        pillola[i + 1].fillColor = { white = 1, alpha = 0.35 + 0.6 * v }
      end
    end)
  end)
end

function disegna.domanda()
  local frase = "Call rilevata, vuoi registrare?"
  local tw = larghezzaTesto(frase, 13)
  local h = 46
  local w = 40 + tw + 12 + 46 + 6 + 46 + 10
  passa(w, h, COL.fondo, function()
    local xs = 40 + tw + 12
    local el = aggiungi({ fondo(w, h) }, microfono(22, h / 2, COL.rosso, 0.85))
    aggiungi(el, {
      testo(frase, 40, 14, tw, 20, 13, COL.testo),
      { type = "rectangle", action = "fill", fillColor = COL.verde, roundedRectRadii = { xRadius = 14, yRadius = 14 },
        frame = { x = xs, y = 9, w = 46, h = 28 }, trackMouseDown = true, id = "si" },
      testo("Sì", xs, 14, 46, 20, 13, COL.testo, "si", "center", true),
      { type = "rectangle", action = "fill", fillColor = COL.grigio, roundedRectRadii = { xRadius = 14, yRadius = 14 },
        frame = { x = xs + 52, y = 9, w = 46, h = 28 }, trackMouseDown = true, id = "no" },
      testo("No", xs + 52, 14, 46, 20, 13, COL.testo, "no", "center", true),
    })
    pillola:replaceElements(table.unpack(el))
  end)
end

function disegna.call()  -- durante la call: linguetta verticale sottile, non ingombra
  local w, h = 24, 72
  passa(w, h, COL.fondo, function()
    pillola:replaceElements(fondo(w, h),
      { type = "circle", action = "fill", fillColor = COL.rosso, center = { x = w / 2, y = 20 }, radius = 4.5 },
      { type = "rectangle", action = "fill", fillColor = COL.grigio, roundedRectRadii = { xRadius = 9, yRadius = 9 },
        frame = { x = 3, y = 42, w = 18, h = 18 }, trackMouseDown = true, id = "stop" },
      { type = "rectangle", action = "fill", fillColor = COL.testo, roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
        frame = { x = 8.5, y = 47.5, w = 7, h = 7 }, trackMouseDown = true, id = "stop" })
    local fase = 0
    animazione = hs.timer.doEvery(1 / 20, function()
      fase = fase + 0.12
      pillola[2].fillColor = { red = 1, green = 0.3, blue = 0.3, alpha = 0.4 + 0.6 * (0.5 + 0.5 * math.sin(fase)) }
    end)
  end)
end

local function tempoCall()
  local s = os.time() - (callInizio or os.time())
  if s >= 3600 then return string.format("%d:%02d:%02d", s // 3600, (s % 3600) // 60, s % 60) end
  return string.format("%02d:%02d", s // 60, s % 60)
end

function disegna.callSopra()  -- mouse sopra la linguetta della call: mostra il tempo
  local w, h = 146, 40
  passa(w, h, COL.fondo, function()
    pillola:replaceElements(fondo(w, h),
      { type = "circle", action = "fill", fillColor = COL.rosso, center = { x = 20, y = h / 2 }, radius = 4.5 },
      testo("REC " .. tempoCall(), 32, 11, 70, 20, 13, COL.testo, nil, "left", true),
      { type = "rectangle", action = "fill", fillColor = COL.grigio, roundedRectRadii = { xRadius = 14, yRadius = 14 },
        frame = { x = 110, y = 6, w = 28, h = 28 }, trackMouseDown = true, id = "stop" },
      { type = "rectangle", action = "fill", fillColor = COL.rosso, roundedRectRadii = { xRadius = 2, yRadius = 2 },
        frame = { x = 119, y = 15, w = 10, h = 10 }, trackMouseDown = true, id = "stop" })
    orologio = hs.timer.doEvery(1, function()
      pillola[3].text = hs.styledtext.new("REC " .. tempoCall(), stile(13, COL.testo, "left", true))
    end)
  end)
end

local function mostra(stato)
  fermaAnimazioni()
  D.stato = stato
  disegna[stato]()
end
D.mostra = mostra

---------------------------------------------------------------- dettatura
local function avviaServer()
  if server and server:isRunning() then return end
  server = hs.task.new(SERVER, nil, { "-m", MODELLO, "-l", "it", "--host", "127.0.0.1", "--port", tostring(PORTA) })
  server:start()
end

local function rinviaSpegnimento()
  if timerSpegni then timerSpegni:stop() end
  timerSpegni = hs.timer.doAfter(SPEGNI_DOPO, function()
    if server and server:isRunning() then server:terminate() end
    server = nil
  end)
end

local function pulisci(t)
  t = t:gsub("%[[^%]]*%]", ""):gsub("%([^%)]*%)", "")
  for _, w in ipairs({ "ehm", "ehmm", "uhm", "mmm", "ehh" }) do
    t = t:gsub("%f[%a]" .. w .. "%f[%A],?%s*", "")
    t = t:gsub("%f[%a]" .. w:gsub("^%l", string.upper) .. "%f[%A],?%s*", "")
  end
  return (t:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function incolla(t)
  -- Solo per le prove con `hs -c`: D.senzaIncolla = istante (secondi) fino a cui non si incolla.
  -- È una scadenza e non un sì/no, così una prova dimenticata non blocca la dettatura per sempre.
  if type(D.senzaIncolla) == "number" and hs.timer.secondsSinceEpoch() < D.senzaIncolla then
    D.ultimoIncollato = t; return
  end
  local prima = hs.pasteboard.getContents()
  hs.pasteboard.setContents(t)
  hs.eventtap.keyStroke({ "cmd" }, "v", 0)
  suona("incolla")
  dopo(0.8, function() if prima then hs.pasteboard.setContents(prima) end end)
end

local function tornaARiposo()
  if callInizio then mostra("call") else mostra("riposo") end
end

-- Dizionario sul testo (nt.cli applica), poi incolla e salva nello storico. Se il dizionario non risponde
-- si incolla il testo così com'è: la dettatura non deve mai bloccarsi per colpa del Notetaker.
local function finisciTesto(grezzo, app, durata)
  local fatto = false
  local function chiudi(finale)
    if fatto then return end
    fatto = true
    tornaARiposo()
    if finale ~= "" then incolla(finale) end
    hs.task.new(PYTHON, nil, { "-m", "nt.cli", "salva-dettatura", "--grezzo=" .. grezzo, "--finale=" .. finale,
                               "--app=" .. (app or ""), "--durata=" .. string.format("%.1f", durata or 0) })
      :setWorkingDirectory(CARTELLA):start()
  end
  local t = hs.task.new(PYTHON, function(codice, out, _)
    chiudi((codice == 0 and out and out ~= "") and out or grezzo)
  end, { "-m", "nt.cli", "applica" })
  t:setWorkingDirectory(CARTELLA)
  t:setInput(grezzo)
  if not t:start() then chiudi(grezzo) end
  dopo(1.5, function() chiudi(grezzo) end)
end

local function trascrivi(file, app, durata, tentativo)
  tentativo = tentativo or 1
  hs.task.new(CURL, function(codice, out, _)
    if codice ~= 0 or not out or out == "" then
      if tentativo < 20 then
        dopo(1, function() trascrivi(file, app, durata, tentativo + 1) end) -- il server sta partendo
      else
        hs.alert.show("Dettatura: trascrizione non riuscita"); tornaARiposo(); os.remove(file)
      end
      return
    end
    os.remove(file)
    local t = pulisci(out)
    if t ~= "" then finisciTesto(t, app, durata) else tornaARiposo() end
    rinviaSpegnimento()
  end, { "-s", "--max-time", "60", "-F", "file=@" .. file, "-F", "response_format=text",
         "-F", "temperature=0", "--form-string", "prompt=" .. promptWhisper,
         "http://127.0.0.1:" .. PORTA .. "/inference" }):start()
end

-- Se una call si sta registrando, il microfono è condiviso: l'intervallo della dettatura si annota nella
-- cartella della call, così la diretta e la trascrizione finale lo tolgono (la dettatura resta solo nello storico).
function segnaDettaturaInCall(da, a)  -- a = nil: la dettatura è appena iniziata
  if not callInizio or not da then return end
  local f = io.open(CARTELLA .. "/stato", "r")
  if not f then return end
  f:read("l"); local cartella = f:read("l"); f:close()
  if not cartella or cartella == "" then return end
  local out = io.open(cartella .. "/dettature-in-call.jsonl", "a")
  if out then out:write(hs.json.encode({ da = da, a = a }), "\n"); out:close() end
end

-- Il microfono del Mac impiega 0,3-0,9 s ad accendersi: la cattura parte appena si preme il tasto,
-- e suono e pillola "in ascolto" arrivano solo con il primo audio vero, così non si perde l'inizio.
-- Una cattura non confermata (un tocco, Fn+altro tasto) si butta senza suoni.
local cattura = nil   -- { task, file, avvio, confermata, pronta, segnalata }
local nCattura = 0
D.registroFn = {}     -- ultimi eventi del tasto, per capire i casi strani: hs -c 'hs.inspect(D.registroFn)'
local function annota(evento)
  local r = D.registroFn
  r[#r + 1] = string.format("%.3f %s", hs.timer.secondsSinceEpoch() % 1000, evento)
  if #r > 60 then table.remove(r, 1) end
end

local function segnalaAscolto(c)  -- suono e pillola: solo quando la cattura è confermata e l'audio arriva
  if not c or c ~= cattura or not c.confermata or not c.pronta or c.segnalata then return end
  c.segnalata = true
  suona(maniLibere and "blocco" or "avvio")
  mostra("ascolto")
  annota("in ascolto")
end

local function avviaCattura()
  if cattura or D.stato == "trascrivo" then return end
  avviaServer()
  local mic = hs.audiodevice.defaultInputDevice()
  if IMP.microfono ~= "" then mic = hs.audiodevice.findInputByName(IMP.microfono) or mic end
  local nome = mic and mic:name() or "default"
  nCattura = nCattura + 1
  local c = { file = TMP .. "dettatura-" .. nCattura .. ".wav", avvio = hs.timer.secondsSinceEpoch() }
  livello = 0
  c.task = hs.task.new(FFMPEG, nil, function(_, out, _)
    for db in (out or ""):gmatch("RMS_level=(%-?[%d%.]+)") do
      local v = math.max(0, math.min(1, (tonumber(db) + 58) / 38))
      livello = livello * 0.35 + v * 0.65
    end
    if not c.pronta and c == cattura then c.pronta = true; annota("primo audio"); segnalaAscolto(c) end
    return true
  end, { "-nostdin", "-loglevel", "error", "-y", "-f", "avfoundation", "-i", ":" .. nome,
         "-filter_complex", "[0:a]aresample=16000,aformat=channel_layouts=mono,asplit=2[o][m];" ..
         "[m]asetnsamples=n=1000,astats=metadata=1:reset=1," ..
         "ametadata=mode=print:key=lavfi.astats.Overall.RMS_level:file=/dev/stdout:direct=1,anullsink",
         "-map", "[o]", c.file })
  cattura = c
  c.task:start()
  annota("cattura avviata")
end

local function annullaCattura()  -- solo per catture non confermate: niente suoni, niente file
  local c = cattura
  if not c or c.confermata then return end
  cattura = nil
  c.task:interrupt()
  aspetta(function() return not c.task:isRunning() end, function() os.remove(c.file) end, 0.05)
  annota("cattura buttata")
end

local function confermaDettatura(libere)
  if not cattura then avviaCattura() end
  local c = cattura
  if not c or c.confermata then return end
  c.confermata = true
  registrazione = c.task
  maniLibere = libere and true or false
  inizioDettatura = c.avvio
  segnaDettaturaInCall(inizioDettatura, nil)
  local fronte = hs.application.frontmostApplication()
  appDettatura = fronte and fronte:name() or ""
  annota(maniLibere and "confermata: mani libere" or "confermata: tasto tenuto")
  segnalaAscolto(c)
end

local function iniziaDettatura(libere)
  if registrazione or D.stato == "trascrivo" then return end
  confermaDettatura(libere)
end

local function fineDettatura(annulla)
  local c = cattura
  if not c then return end
  if not c.confermata then annullaCattura(); return end
  cattura, registrazione, maniLibere = nil, nil, false
  c.task:interrupt()
  segnaDettaturaInCall(inizioDettatura, hs.timer.secondsSinceEpoch())
  local durata = hs.timer.secondsSinceEpoch() - c.avvio
  annota(annulla and "annullata" or "finita")
  if annulla then suona("annulla"); tornaARiposo() else suona("stop"); mostra("trascrivo") end
  aspetta(function() return not c.task:isRunning() end, function()
    if annulla then os.remove(c.file) return end
    local a = hs.fs.attributes(c.file)
    if a and a.size > 16000 then trascrivi(c.file, appDettatura, durata) else os.remove(c.file); tornaARiposo() end
  end, 0.05)
end
D.iniziaDettatura, D.fineDettatura = iniziaDettatura, fineDettatura

-- Tasto di dettatura (Fn, keyCode 63, oppure Option destro, keyCode 61, dalle impostazioni):
-- tenuto = dettatura; due tocchi = mani libere (un altro tocco finisce); Esc = annulla.
local TASTI = { fn = { codice = 63, flag = "fn" }, option_destro = { codice = 61, flag = "alt" } }
local fnGiu, fnDa, ultimoTocco, altroTasto, pressione = false, 0, 0, false, 0
local tipi = hs.eventtap.event.types
-- I timer vanno tenuti in variabili: se no Hammerspoon può eliminarli prima che scattino.
local timerTieni, timerDoppio = nil, nil
local sorveglia = nil  -- mentre il tasto è giù: se macOS perde l'evento di rilascio, lo si vede dallo stato reale

local function rilascio(ora)
  fnGiu = false
  if sorveglia then sorveglia:stop(); sorveglia = nil end
  if fnDa < 0 then return end                                   -- pressione che ha chiuso le mani libere
  if registrazione and not maniLibere then
    fineDettatura(altroTasto)                                   -- fine della dettatura col tasto tenuto
  elseif not altroTasto and ora - fnDa < TIENI then             -- è stato un tocco
    if fnDa - ultimoTocco < DOPPIO then
      ultimoTocco = 0
      annota("doppio tocco")
      confermaDettatura(true)                                   -- la cattura è già accesa: niente attesa
    else
      ultimoTocco = fnDa
      annota("primo tocco")
      local id = pressione
      if timerDoppio then timerDoppio:stop() end
      timerDoppio = hs.timer.doAfter(DOPPIO, function()         -- nessun secondo tocco: si butta la cattura
        if pressione == id and not fnGiu then annullaCattura() end
      end)
    end
  else
    annullaCattura()
  end
end

tastoFn = hs.eventtap.new({ tipi.flagsChanged, tipi.keyDown }, function(e)
  if e:getType() == tipi.keyDown then
    local k = e:getKeyCode()
    if registrazione and k == 53 then fineDettatura(true); return true end   -- Esc
    if fnGiu then
      altroTasto = true                                                       -- Fn+altro tasto: non è dettatura
      if registrazione and not maniLibere then fineDettatura(true) else annullaCattura() end
    end
    return false
  end
  local tasto = TASTI[IMP.tasto] or TASTI.fn
  if e:getKeyCode() ~= tasto.codice then return false end
  local giu = e:getFlags()[tasto.flag] and true or false
  local ora = hs.timer.secondsSinceEpoch()
  annota(giu and "giù" or "su")
  if giu and fnGiu then rilascio(ora) end    -- macOS a volte perde il rilascio di un tocco rapidissimo
  if giu and not fnGiu then
    fnGiu, fnDa, altroTasto = true, ora, false
    pressione = pressione + 1
    if registrazione and maniLibere then fineDettatura(false); fnDa = -1; return false end
    avviaCattura()                           -- il microfono si accende subito (se non è già acceso)
    local id = pressione
    if sorveglia then sorveglia:stop() end
    sorveglia = hs.timer.doEvery(0.05, function()
      if pressione == id and fnGiu and not hs.eventtap.checkKeyboardModifiers()[tasto.flag] then
        annota("su perso: rilascio dallo stato dei tasti")
        rilascio(hs.timer.secondsSinceEpoch())
      end
    end)
    if timerTieni then timerTieni:stop() end
    timerTieni = hs.timer.doAfter(TIENI, function()  -- ancora giù dopo TIENI, stessa pressione: dettatura col tasto
      if pressione == id and fnGiu and not altroTasto and not registrazione then confermaDettatura(false) end
    end)
  elseif not giu and fnGiu then
    rilascio(ora)
  end
  return false
end)
tastoFn:start()

---------------------------------------------------------------- call
local APP_CALL = {
  ["us.zoom.xos"] = "Zoom", ["com.microsoft.teams2"] = "Teams", ["com.microsoft.teams"] = "Teams",
  ["com.apple.FaceTime"] = "FaceTime", ["net.whatsapp.WhatsApp"] = "WhatsApp",
  ["com.tinyspeck.slackmacgap"] = "Slack", ["com.hnc.Discord"] = "Discord",
  ["ru.keepcoder.Telegram"] = "Telegram", ["com.cisco.webexmeetingsapp"] = "Webex",
}
local BROWSER = { "Google Chrome", "Safari", "Arc", "Firefox", "Microsoft Edge", "Brave Browser" }
local TITOLI = { { "Meet", "Google Meet" }, { "Zoom", "Zoom" }, { "Microsoft Teams", "Teams" },
                 { "Teams", "Teams" }, { "Whereby", "Whereby" }, { "Jitsi", "Jitsi" } }

local function trovaAppCall()
  for _, b in ipairs(BROWSER) do
    local app = hs.application.get(b)
    if app then
      for _, w in ipairs(app:allWindows()) do
        local t = w:title() or ""
        for _, coppia in ipairs(TITOLI) do
          if t:find(coppia[1], 1, true) then return coppia[2] end
        end
      end
    end
  end
  for id, nome in pairs(APP_CALL) do
    if hs.application.get(id) then return nome end
  end
  return nil
end

local function callAttiva()
  return hs.execute(CALL .. " stato"):find("Sto registrando") ~= nil
end

local function avviaCall()
  local bottone, nome = hs.dialog.textPrompt("Trascrivi la call", "Con chi è la call? (più persone: Marco, Giulia)", "", "Avvia", "Annulla")
  if bottone ~= "Avvia" then micIgnora = true; mostra("riposo"); return end
  nome = nome:gsub('[%$`"\\/:%*%?<>|#%^%[%]]', ""):gsub("^%s+", ""):gsub("%s+$", "")
  if nome == "" then nome = "Interlocutore" end
  local esito = hs.execute(CALL .. " avvia " .. string.format("%q", nome))
  if esito:find("avviata") then
    callInizio = os.time()
    suona("blocco")
    mostra("call")
    hs.alert.show("Registro la call con " .. nome .. ". Ricorda di chiedere il consenso.", 4)
  else
    hs.alert.show(esito, 5); mostra("riposo")
  end
end

local function fermaCall()
  hs.execute(CALL .. " ferma")
  callInizio = nil
  micIgnora = true -- la call è ancora aperta: non riproporre finché il microfono non si libera
  suona("stop")
  mostra("riposo")
  hs.alert.show("Call fermata: trascrivo, ti arriva una notifica", 3)
end

function apriNotetaker()
  hs.execute("/usr/bin/open " .. string.format("%q", NOTETAKER))
end
D.apriNotetaker = apriNotetaker

pillola:mouseCallback(function(_, evento, id)
  if evento == "mouseEnter" and D.stato == "riposo" then mostra("sopra"); return end
  if evento == "mouseExit" and D.stato == "sopra" then mostra("riposo"); return end
  if evento == "mouseEnter" and D.stato == "call" then mostra("callSopra"); return end
  if evento == "mouseExit" and D.stato == "callSopra" then mostra("call"); return end
  if evento ~= "mouseDown" then return end
  local tasti, mod = hs.eventtap.checkMouseButtons(), hs.eventtap.checkKeyboardModifiers()
  if (tasti.right or mod.ctrl) and D.stato ~= "domanda" then apriNotetaker(); return end
  if D.stato == "domanda" then
    if id == "si" then avviaCall() elseif id == "no" then micIgnora = true; mostra("riposo") end
  elseif D.stato == "call" or D.stato == "callSopra" then
    if id == "stop" then fermaCall() end
  elseif D.stato == "sopra" and id == "registraCall" then
    avviaCall()              -- il pallino rosso sotto il microfono: chiede con chi è la call e registra
  elseif D.stato == "riposo" or D.stato == "sopra" then
    iniziaDettatura(true)    -- dal clic: mani libere, si finisce con un altro clic o con Fn
  elseif D.stato == "ascolto" then
    fineDettatura(false)
  end
end)

-- Ogni 2 secondi: un'app di call sta usando il microfono? Dopo qualche secondo la pillola chiede.
controlloMic = hs.timer.doEvery(2, function()
  if registrazione or cattura or D.stato == "trascrivo" or callInizio then micDa = nil; return end
  local mic = hs.audiodevice.defaultInputDevice()
  local inUso = mic and mic:inUse()
  if not inUso then
    micDa, micIgnora = nil, false
    if D.stato == "domanda" then mostra("riposo") end
    return
  end
  if D.stato == "domanda" then
    if domandaScade and os.time() > domandaScade then micIgnora = true; mostra("riposo") end
    return
  end
  if micIgnora or not IMP.domanda_call or (D.stato ~= "riposo" and D.stato ~= "sopra") then return end
  micDa = micDa or os.time()
  if os.time() - micDa >= IMP.secondi_domanda then
    appCallAttuale = trovaAppCall()
    if appCallAttuale then
      domandaScade = os.time() + 30
      suona("domanda")
      mostra("domanda")
    end
  end
end)

hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "R", function()
  if callInizio or callAttiva() then fermaCall() else avviaCall() end
end)
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "N", apriNotetaker)

-- Il canvas non riceve il clic destro: lo si intercetta qui, solo se cade sulla pillola.
clicDestro = hs.eventtap.new({ hs.eventtap.event.types.rightMouseDown }, function(e)
  local p, f = e:location(), pillola:frame()
  if pillola:isShowing() and p.x >= f.x and p.x <= f.x + f.w and p.y >= f.y and p.y <= f.y + f.h then
    apriNotetaker(); return true
  end
  return false
end):start()

-- Le impostazioni e il dizionario cambiano dal Notetaker: si rileggono appena il file cambia.
osservaDati = hs.pathwatcher.new(DATI, function(file)
  for _, f in ipairs(file) do
    if f:match("impostazioni%.json$") then caricaImpostazioni(); volumeSuoni() end
    if f:match("dizionario%.json$") then aggiornaPrompt() end
  end
end):start()

hs.autoLaunch(true)  -- Hammerspoon parte sempre al login: senza, niente pillola né dettatura

if callAttiva() then callInizio = os.time(); mostra("call") else mostra("riposo") end
hs.screen.watcher.new(function() fondoAttuale = { w = 10, h = 54 }; disegna[D.stato]() end):start()
