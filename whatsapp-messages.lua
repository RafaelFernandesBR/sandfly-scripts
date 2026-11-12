local manifest = {
  id = 'whatsapp-messages',
  name = 'WhatsApp messages',
  version = '3.13',
  author = 'Aaron Hewitt',
  minApiVersion = 2,
  testedApiVersion = 2,
  description = 'Reads each message in a WhatsApp chat as one item: sender, content, the message it replies to, and time. Play, playback speed and the other buttons in a message are in its Actions menu. In the chat list, each contact is one item, without a separate item for its photo. A swipe left then right advances the focused voice message, right then left rewinds it. Optionally describes downloaded photos, in chats and in status updates (never videos), using the Gemini API.',
  apps = {
    { package = 'com.whatsapp', activity = 'Conversation' },
    { package = 'com.whatsapp.w4b', activity = 'Conversation' },
    { package = 'com.whatsapp', activity = 'HomeActivity' },
    { package = 'com.whatsapp.w4b', activity = 'HomeActivity' },
    { package = 'com.whatsapp', activity = 'StatusPlaybackActivity' },
    { package = 'com.whatsapp.w4b', activity = 'StatusPlaybackActivity' },
  },
  permissions = { 'screen', 'actions', 'speech', 'input', 'java', 'network' },
  settings = {
    { key = 'expandLong', type = 'switch', title = 'Expand long messages', default = true },
    { key = 'describePhotos', type = 'switch', title = 'Describe downloaded photos automatically', default = false },
    { key = 'geminiApiKey', type = 'text', title = 'Gemini API key', default = '' },
  },
  commands = {
    { id = 'audioForward', title = 'Advance voice message', gesture = 'swipeLeftThenRight' },
    { id = 'audioBackward', title = 'Rewind voice message', gesture = 'swipeRightThenLeft' },
  },
  rules = {
    -- A voice message, audio file, or media not yet downloaded has a play/pause or download button,
    -- control_btn. A double-tap presses it; rows without one fall back to their usual target.
    { match = { parentId = 'list', className = 'ViewGroup' }, group = true, activate = { id = 'control_btn' } },
    {
      match = { clickable = true, inside = { parentId = 'list', className = 'ViewGroup' } },
      hide = 'all',
    },
    {
      match = { className = 'SeekBar', inside = { parentId = 'list', className = 'ViewGroup' } },
      hide = true,
      silence = true,
    },
    -- A voice message's time, which counts up each second while it plays.
    { match = { id = 'description', inside = { parentId = 'list', className = 'ViewGroup' } }, silence = true },
    -- In the chat list, a contact's photo is its own clickable node nested in the row, so it
    -- would otherwise show up as a second item next to the row that opens the chat.
    { match = { clickable = true, inside = { id = 'contact_row_container' } }, hide = 'all' },
  },
}

local tr = sf._

-- A message row is read with one search, which gives the row and everything in it, so that the
-- rest of the script looks things up in the script instead of asking WhatsApp again. Every call
-- to the app takes time, more than the 30 milliseconds SandFly waits for onFocus, so the row is
-- read after onFocus returns and said when it is ready.
local MAX_ROW_ITEMS = 200
local MAX_BUTTONS = 24
local MAX_OPTIONS = 20
local MAX_REACTIONS = 8
local MAX_NOTICES = 5
local LABEL_DEPTH = 3
local MAX_BUBBLE_ITEMS = 60
local MAX_BUBBLE_TEXTS = 6

local function present(text)
  if text ~= nil and text ~= '' then
    return text
  end
end

-- Joins the parts that aren't nil, false or empty.
local function join(parts, separator)
  local kept = {}
  for i = 1, parts.n or #parts do
    local part = parts[i]
    if part and part ~= '' then
      kept[#kept + 1] = part
    end
  end
  return table.concat(kept, separator)
end

local function short_id(item)
  return (item.id or ''):match('[^/]*$')
end

-- Removes the direction marks WhatsApp adds, U+200B to U+200F, U+202A to U+202E and U+2066 to
-- U+2069, and the "~" before a name the contact list doesn't have.
local function clean(text)
  text = (text or ''):gsub('\226\128[\139-\143\170-\174]', '')
  text = text:gsub('\226\129[\166-\169]', '')
  -- The narrow no-break space after the "~", U+202F.
  text = text:gsub('\226\128\175', ' ')
  text = text:match('^%s*(.-)%s*$')
  text = text:gsub('^~%s*', '')
  return (text:match('^%s*(.-)%s*$'))
end

-- Gives the list of messages that the row is in, or nil if the item isn't a message row.
local function list_of(item)
  if short_id(item):sub(1, 17) ~= 'conversation_row_' then
    return nil
  end
  local parent = item:parent()
  if parent and (parent.id or ''):sub(-5) == '/list' then
    return parent
  end
end

-- The row and everything in it, by short id.
local function read_row(row, list)
  local items = row:findAll({}, MAX_ROW_ITEMS)
  local by_id = {}
  for _, item in ipairs(items) do
    local id = short_id(item)
    if id ~= '' then
      local found = by_id[id]
      if not found then
        found = {}
        by_id[id] = found
      end
      found[#found + 1] = item
    end
  end
  return { node = row, list = list, items = items, by_id = by_id }
end

local function first(r, id)
  local found = r.by_id[id]
  return found and found[1]
end

local function all_of(r, id, limit)
  local found = r.by_id[id] or {}
  local result = {}
  for i = 1, math.min(#found, limit) do
    result[i] = found[i]
  end
  return result
end

local function text_in(r, id)
  local found = first(r, id)
  return found and clean(found.text) or ''
end

local function main_of(r)
  return first(r, 'main_layout') or first(r, 'polls_main_layout')
end

-- Sent messages have a delivery status and sit against the right edge.
local function is_outgoing(r)
  if first(r, 'status') then
    return true
  end
  local main = main_of(r)
  local row = r.node
  return main ~= nil and row.bounds.right - main.bounds.right < main.bounds.left - row.bounds.left
end

-- Whether the chat is a group, and the contact's name if not, kept for each chat.
local chats = {}

-- In a chat with one person, the messages from them have no name and no picture.
local function contact_name(list)
  if not list then
    return ''
  end
  local chat = chats[list.handle]
  if not chat then
    local is_group = false
    for _, id in ipairs({ 'name_in_group_tv', 'group_profile_pic', 'group_profile_initials' }) do
      if list:find(id) then
        is_group = true
        break
      end
    end
    local title = not is_group and sf.screen.find('conversation_contact_name') or nil
    chat = { name = title and clean(title.text) or '' }
    chats[list.handle] = chat
  end
  return chat.name
end

-- Splits "54 seconds, 09:11, played" into the body, the time and what follows the time.
local function split_time(rest)
  local init = 1
  while true do
    local s, e, time = rest:find(',%s*(%d%d?:%d%d)', init)
    if not s then
      return nil
    end
    local tail = rest:sub(e + 1)
    local ampm = tail:match('^%s?[aApP][mM]')
    if ampm then
      time = time .. ampm
      tail = tail:sub(#ampm + 1)
    end
    if tail == '' then
      return rest:sub(1, s - 1), time, nil
    end
    local state = tail:match('^,%s*(.*)$')
    if state then
      return rest:sub(1, s - 1), time, state
    end
    init = s + 1
  end
end

-- "Alex Smith, voice message, 54 seconds, 09:11" has the sender first, and the time and "played"
-- last. A sound file reads "audio message" instead, and its row also shows the file name.
local function voice_of(r)
  if r.voice == nil then
    r.voice = false
    local main = first(r, 'main_layout')
    local description = main and main.contentDescription or ''
    local voice_at = description:find(', voice message', 1, true)
    local audio_at = description:find(', audio message', 1, true)
    local at = voice_at and audio_at and math.min(voice_at, audio_at) or voice_at or audio_at
    if at then
      local rest = description:sub(at + 2)
      local file = short_id(r.node) == 'conversation_row_audio' and text_in(r, 'description') or ''
      local body, time, state = split_time(rest)
      r.voice = {
        sender = clean(description:sub(1, at - 1)),
        body = join({ body or rest, file }, ', '),
        time = time or '',
        state = state or '',
      }
    end
  end
  return r.voice or nil
end

-- "Poll from Alex Smith, next event.\nSelect one or more\n..."; each option reads "Name, 2 votes".
local function poll_of(r)
  if r.poll == nil then
    r.poll = false
    local main = first(r, 'polls_main_layout')
    if main then
      local name = text_in(r, 'poll_name')
      local description = main.contentDescription or ''
      local end_at = description:find(', ' .. name .. '.', 1, true)
      local parts = { tr('poll') .. ': ' .. name, text_in(r, 'poll_type_text') }
      for _, option in ipairs(all_of(r, 'poll_option_main_layout', MAX_OPTIONS)) do
        local label = clean(option.contentDescription)
        parts[#parts + 1] = option.checked and (tr('selected') .. ' ' .. label) or label
      end
      local prefix = 'Poll from '
      r.poll = {
        sender = description:sub(1, #prefix) == prefix and end_at
            and clean(description:sub(#prefix + 1, end_at - 1)) or '',
        body = join(parts, '. '),
      }
    end
  end
  return r.poll or nil
end

-- A message from the same sender as the one before it has no name of its own.
local function sender_of(r, depth)
  depth = depth or 3
  local named = text_in(r, 'name_in_group_tv')
  if named ~= '' then
    return named
  end
  local known = (voice_of(r) or poll_of(r) or {}).sender
  if present(known) then
    return known
  end
  if is_outgoing(r) then
    return tr('You')
  end
  if depth > 0 and r.list then
    local rows = r.rows or r.list:children()
    for i, sibling in ipairs(rows) do
      if sibling == r.node then
        local previous = i > 1 and rows[i - 1] or nil
        if previous then
          local p = read_row(previous, r.list)
          p.rows = rows
          if not is_outgoing(p) then
            local name = present(sender_of(p, depth - 1))
            if name then
              return name
            end
          end
        end
        break
      end
    end
  end
  return contact_name(r.list)
end

-- "Voice message, 2 minutes, 33 seconds elapsed"; "0 seconds elapsed" before it has played.
local function elapsed_of(r)
  local seek_bar = first(r, 'audio_seekbar')
  local elapsed = seek_bar and (seek_bar.contentDescription or ''):match('^Voice message, (.*) elapsed$')
  if elapsed and elapsed ~= '0 seconds' then
    return elapsed .. ' ' .. tr('elapsed')
  end
  return ''
end

local function label_of(item, depth)
  depth = depth or LABEL_DEPTH
  local own = clean(present(item.contentDescription) or item.text)
  if own ~= '' or depth == 0 then
    return own
  end
  for _, child in ipairs(item:children()) do
    local label = label_of(child, depth - 1)
    if label ~= '' then
      return label
    end
  end
  return ''
end

local function document_of(r)
  if short_id(r.node) ~= 'conversation_row_document' then
    return ''
  end
  local content = first(r, 'content')
  local label = content and label_of(content) or ''
  return label ~= '' and (tr('document') .. ': ' .. label) or tr('document')
end

-- "Enlarge photo", or "Photo 331 kB" before it is downloaded.
local function photo_of(r)
  if short_id(r.node) ~= 'conversation_row_image' then
    return ''
  end
  local image = first(r, 'image')
  local label = clean(image and image.contentDescription)
  if label == '' or label:lower() == 'enlarge photo' then
    return tr('photo')
  end
  if label:sub(1, 5):lower() == 'photo' then
    return tr('photo') .. label:sub(6)
  end
  return label
end

-- Whether the photo is downloaded, checked the same way the manifest's own rules do: a photo (or
-- any other media) still downloading has a play/pause or download button, control_btn (see the
-- comment on the control_btn rule above). Unlike photo_of's "Enlarge photo" vs. "Photo 331 kB",
-- this doesn't depend on WhatsApp's content-desc being in English -- confirmed live, this device's
-- WhatsApp is in Portuguese and says "Aumentar foto" for a downloaded photo, not "Enlarge photo".
local function photo_downloaded(r)
  if short_id(r.node) ~= 'conversation_row_image' then
    return false
  end
  return first(r, 'control_btn') == nil
end

-- The quote's frame and holder have no text of their own, so Android leaves them out of what a
-- screen reader sees; only the quote's title and text are there.
local function reply_of(r)
  local author = text_in(r, 'quoted_title')
  local quoted = text_in(r, 'quoted_text')
  if author == '' and quoted == '' then
    return ''
  end
  return join({ (tr('in reply to') .. ' ' .. author):match('^%s*(.-)%s*$'), quoted }, ': ')
end

-- A link's preview repeats the link; only a title that isn't the address is worth saying, unless
-- the message is only the link, which WhatsApp then shows as the preview alone.
local function preview_of(r, alone)
  local title = text_in(r, 'title')
  local is_address = title:find('^https?://') or title:find('^www%.')
  local named
  if title ~= '' and not is_address then
    named = title
  elseif alone then
    named = present(text_in(r, 'url')) or title
  end
  if not present(named) then
    return ''
  end
  return tr(first(r, 'play_button') and 'video link' or 'link') .. ': ' .. named
end

-- The time and status are said on their own, so a message of a kind not handled above is read
-- from the rest of the text in its bubble.
local SKIP_IDS = {
  date = true, status = true, name_in_group_tv = true, secondary_name_in_group_tv = true,
  conversation_row_date_divider = true, group_profile_initials = true,
}
local function bubble_text_of(r)
  -- A text message's bubble has nothing to say of its own, so screen readers don't see it.
  local main = main_of(r) or r.node
  local texts, seen = {}, {}
  for _, item in ipairs(main:findAll({}, MAX_BUBBLE_ITEMS)) do
    if #texts >= MAX_BUBBLE_TEXTS then
      break
    end
    if not SKIP_IDS[short_id(item)] then
      local own = clean(present(item.contentDescription) or item.text)
      if own ~= '' and not seen[own] then
        seen[own] = true
        texts[#texts + 1] = own
      end
    end
  end
  return table.concat(texts, ', ')
end

local function reactions_of(r)
  local reactions = {}
  for _, reaction in ipairs(all_of(r, 'reaction_bubble_emoji_text', MAX_REACTIONS)) do
    reactions[#reactions + 1] = clean(reaction.text)
  end
  if #reactions == 0 then
    return ''
  end
  return tr('reactions') .. ' ' .. table.concat(reactions, ' ')
end

local function describe(r)
  local voice = voice_of(r)
  local poll = not voice and poll_of(r) or nil
  local body
  if voice then
    body = voice.body
  elseif poll then
    body = poll.body
  else
    local text = present(text_in(r, 'message_text')) or text_in(r, 'caption')
    body = join({ present(document_of(r)) or photo_of(r), text }, ', ')
  end
  local notices = {}
  for _, info in ipairs(all_of(r, 'info', MAX_NOTICES)) do
    notices[#notices + 1] = clean(info.text)
  end
  local preview = preview_of(r, body == '')
  local other = (body == '' and preview == '') and bubble_text_of(r) or ''
  if body == '' and preview == '' and other == '' then
    return #notices > 0 and table.concat(notices, ', ') or nil
  end
  local status = first(r, 'status')
  local time = voice and voice.time or text_in(r, 'date')
  local state = voice and present(voice.state) or (status and status.contentDescription)
  local parts = table.pack(
    sender_of(r),
    present(body) or present(preview) or other,
    voice and elapsed_of(r),
    first(r, 'edit_label') and tr('edited'),
    body ~= '' and preview,
    reply_of(r),
    reactions_of(r),
    join({ time, state, text_in(r, 'conversation_row_date_divider') }, ', ')
  )
  for _, notice in ipairs(notices) do
    parts.n = parts.n + 1
    parts[parts.n] = notice
  end
  return join(parts, ', ')
end

local function read_more_in(r)
  for _, item in ipairs(r.items) do
    if item.contentDescription == 'Read more' then
      return item
    end
  end
end

local EXPAND_ATTEMPTS = 4
local EXPAND_DELAY = 250

-- Each focus is counted, so that a row read after focus moved on isn't said.
local focus_count = 0

-- WhatsApp cuts a long message off in the screen's text, so open it and say the whole message.
local function expand(row, list, read_more, count)
  read_more:click()
  local current = row
  for _ = 1, EXPAND_ATTEMPTS do
    sf.sleep(EXPAND_DELAY)
    current = current:refresh() or current
    if not current:find({ contentDescription = 'Read more' }) then
      break
    end
  end
  local text = describe(read_row(current, list))
  if text and count == focus_count then
    sf.speak(text, { interrupt = true })
  end
end

local expand_long = sf.settings.get('expandLong') ~= false
local describe_photos = sf.settings.get('describePhotos') == true
local gemini_api_key = sf.settings.get('geminiApiKey') or ''
sf.onSettingChange(function(key, value)
  if key == 'expandLong' then
    expand_long = value ~= false
  elseif key == 'describePhotos' then
    describe_photos = value == true
  elseif key == 'geminiApiKey' then
    gemini_api_key = value or ''
  end
end)

sf.onWindowChange(function()
  chats = {}
end)

-- Waited out before capturing a photo to describe, so flicking past several photos quickly (in a
-- chat or in status) doesn't take a screenshot and call the AI for every one of them -- only the
-- one the user is still on once this much time has passed.
local PHOTO_DEBOUNCE_MS = 250

-- Describing a downloaded photo needs the image's actual bytes, which sf.screen never exposes
-- (sf.screen.recognizeText only gives back OCR text, and the bitmap it captures internally is
-- never handed to the script). The 'java' permission's raw LuaJava module is the only way around
-- that: TalkBackService.getInstance() is the same AccessibilityService instance SandFly's own
-- recognizeText calls takeScreenshot() on, so a script can call takeScreenshot() itself and keep
-- the Bitmap instead of letting SandFly discard it after OCR. Confirmed live on device: LuaJava
-- here needs ':' (not '.') for every method call, including static ones, and a java.proxy callback
-- gets the proxy object itself as a leading argument before the real parameter.
-- The device's language, the same source image-describer/main.lua uses (java.util.Locale),
-- normalized the same way ("pt-BR" -> "pt_BR"). Falls back to pt_BR if java access fails for any
-- reason, so a transient reflection problem doesn't block the description.
local function device_language()
  local ok, locale = pcall(function()
    return java.import('java.util.Locale'):getDefault():toString()
  end)
  if ok and locale and locale ~= '' then
    return (locale:gsub('%-%-?', '_'))
  end
  return 'pt_BR'
end

local function describe_prompt(language)
  return 'Describe the image objectively in ' .. language .. ', providing a clear overview of visible elements for '
    .. 'visually impaired users. Follow these rules strictly:\n\n'
    .. '- Start with general scene (who/what/where).\n'
    .. '- Highlight main action and key elements.\n'
    .. '- Transcribe all visible text verbatim.\n'
    .. '- Use present tense and active verbs.\n'
    .. '- Focus on relevant visual information only.\n'
    .. "- No introductions, opinions, 'image of', emojis, or redundant phrases.\n"
    .. '- Answer only in ' .. language .. ', pure description.\n\n'
    .. 'Describe following this exact structure.'
end

-- Crops [bitmap] to the node bounds [b] ({left,top,right,bottom}), clamped to the bitmap itself,
-- same idea as SandFly's own ScriptScreen.cropped() for recognizeText.
local function crop_to_bounds(Bitmap, bitmap, b)
  if not b then
    return bitmap
  end
  local left = math.max(b.left, 0)
  local top = math.max(b.top, 0)
  local right = math.min(b.right, bitmap:getWidth())
  local bottom = math.min(b.bottom, bitmap:getHeight())
  if right - left <= 0 or bottom - top <= 0 then
    return bitmap
  end
  return Bitmap:createBitmap(bitmap, left, top, right - left, bottom - top)
end

-- Takes a screenshot, crops it to [bounds], and gives [done] a base64 JPEG string, or nil and why.
local function capture_base64(bounds, done)
  local ok, err = pcall(function()
    local service = java.import('com.google.android.accessibility.talkback.TalkBackService'):getInstance()
    if service == nil then
      error('TalkBackService is not running')
    end
    local executor = service:getMainExecutor()
    local Display = java.import('android.view.Display')
    local Bitmap = java.import('android.graphics.Bitmap')
    local callback = java.proxy('android.accessibilityservice.AccessibilityService$TakeScreenshotCallback', {
      onSuccess = function(self, result)
        local ok2, err2 = pcall(function()
          local ByteArrayOutputStream = java.import('java.io.ByteArrayOutputStream')
          local Base64 = java.import('android.util.Base64')
          local buffer = result:getHardwareBuffer()
          local bitmap = Bitmap:wrapHardwareBuffer(buffer, result:getColorSpace())
          buffer:close()
          if bitmap == nil then
            error('Could not read the screenshot')
          end
          local software = crop_to_bounds(Bitmap, bitmap:copy(Bitmap.Config.ARGB_8888, false), bounds)
          local stream = ByteArrayOutputStream()
          software:compress(Bitmap.CompressFormat.JPEG, 85, stream)
          done(Base64:encodeToString(stream:toByteArray(), Base64.NO_WRAP), nil)
        end)
        if not ok2 then
          done(nil, tostring(err2))
        end
      end,
      onFailure = function(self, errorCode)
        -- Android allows only a few screenshots a second; a fast double-focus can hit this.
        done(nil, 'takeScreenshot failed: ' .. tostring(errorCode))
      end,
    })
    service:takeScreenshot(Display.DEFAULT_DISPLAY, executor, callback)
  end)
  if not ok then
    done(nil, tostring(err))
  end
end

local function first_text(parts)
  for _, part in ipairs(parts or {}) do
    if type(part.text) == 'string' then
      return part.text
    end
  end
end

-- Same request/response shape already used (and tested) by image-describer/main.lua's Gemini path.
local function fetch_description(base64)
  local url = 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key='
    .. gemini_api_key
  local response = sf.fetch(url, {
    method = 'POST',
    body = {
      systemInstruction = { parts = { { text = describe_prompt(device_language()) } } },
      contents = { { role = 'user', parts = { { inlineData = { mimeType = 'image/jpeg', data = base64 } } } } },
    },
  })
  if not response.ok then
    print('describe_photo: Gemini HTTP ' .. tostring(response.status) .. ': ' .. tostring(response.body))
    return nil
  end
  local data = response:json()
  local candidate = data and data.candidates and data.candidates[1]
  local description = candidate and candidate.content and first_text(candidate.content.parts)
  if not description then
    print('describe_photo: no text in Gemini response: ' .. tostring(response.body))
  end
  return description
end

-- Captures the screenshot within [bounds], asks the configured AI to describe it, and speaks the
-- result -- unless the user has moved on (count ~= focus_count) by the time it comes back. Used
-- both for a downloaded photo in a chat and for a photo status: same bytes-via-java pipeline,
-- same AI call, same staleness guard, so one function covers both call sites below.
-- Failures of any kind (screenshot, network, parsing) are silent to speech (this is an optional
-- add-on to what SandFly already said), but are printed to the script's own Log screen.
local function describe_photo(bounds, count)
  if count ~= focus_count then
    return
  end
  capture_base64(bounds, function(base64, capture_err)
    if not base64 then
      print('describe_photo: capture failed: ' .. tostring(capture_err))
      return
    end
    sf.run(function()
      local ok, description = pcall(fetch_description, base64)
      if not ok then
        print('describe_photo: fetch_description crashed: ' .. tostring(description))
      elseif present(description) and count == focus_count then
        sf.speak(tr('Photo description') .. ': ' .. description, { interrupt = false })
      end
    end)
  end)
end

-- Reads the focused row and says it, or what SandFly would have said, [fallback], if it isn't a
-- message.
local function say_row(item, fallback, count)
  local list = list_of(item)
  local r = list and read_row(item, list)
  local read_more = r and expand_long and read_more_in(r)
  if read_more then
    expand(item, list, read_more, count)
    return
  end
  local text = r and describe(r) or fallback
  if count == focus_count and present(text) then
    sf.speak(text, { interrupt = true })
  end
  local image = r and describe_photos and photo_downloaded(r) and first(r, 'image')
  if image then
    sf.setTimeout(describe_photo, PHOTO_DEBOUNCE_MS, image.bounds, count)
  end
end

sf.onFocus(function(item, text)
  focus_count = focus_count + 1
  local id = short_id(item)
  -- Confirmed live: WhatsApp's status_playback_image (not status_playback_video) is exactly what
  -- SandFly's own accessibility-focus cursor lands on whenever the status shown changes -- even
  -- though it reports focusable="false" in a plain view-hierarchy dump (that attribute is
  -- Android's unrelated *input*-focus concept; accessibility focus is a separate, screen-reader-
  -- only cursor that doesn't require it). A video status focuses status_playback_video instead,
  -- which this simply never matches, so nothing is ever captured or sent for a video.
  if id == 'status_playback_image' then
    if describe_photos then
      sf.setTimeout(describe_photo, PHOTO_DEBOUNCE_MS, item.bounds, focus_count)
    end
    return
  end
  -- Only the id is looked at here, which needs no call to WhatsApp.
  if id:sub(1, 17) ~= 'conversation_row_' then
    return
  end
  -- sf.run would start reading at once, inside onFocus's time, and SandFly turns the script off
  -- when it runs out of time again and again. A timer reads the row once onFocus has returned.
  sf.setTimeout(say_row, 0, item, text, focus_count)
  return false
end)

-- Time to tell whether the seek bar's position is currently advancing on its own (meaning
-- the voice message is playing), and to give WhatsApp's pause/play and seek actions time to
-- take effect.
local PLAY_PROBE_DELAY = 80
local TOGGLE_DELAY = 200

-- Seeks the given voice message row's audio_seekbar one step forward or back.
-- audio_seekbar's own actions (checked live on a device) don't include setProgress, only
-- scrollForward/scrollBackward -- the same idiom vertical-video-gestures.lua already uses
-- for Instagram's Reels pager -- so WhatsApp's own step size is used instead of a fixed
-- number of seconds. scrollForward/scrollBackward only move a *paused* message (confirmed
-- live: scrolling has no audible effect while one is playing), so a playing message is
-- paused first and resumed after, detected by comparing the seek bar's position a moment
-- apart rather than guessing control_btn's play/pause label text.
local function seek(item, list, forward, count)
  local r = read_row(item, list)
  local seekBar = first(r, 'audio_seekbar')
  if not seekBar then
    sf.playSound('beep')
    return
  end
  local controlBtn = first(r, 'control_btn')
  local playing = false
  local before = seekBar.range and seekBar.range.current
  if controlBtn and before then
    sf.sleep(PLAY_PROBE_DELAY)
    seekBar = seekBar:refresh() or seekBar
    local after = seekBar.range and seekBar.range.current
    playing = after ~= nil and after > before
  end
  if playing then
    controlBtn:click()
    sf.sleep(TOGGLE_DELAY)
  end
  if forward then
    seekBar:scrollForward()
  else
    seekBar:scrollBackward()
  end
  sf.sleep(TOGGLE_DELAY)
  if playing then
    controlBtn:click()
  end
  seekBar = seekBar:refresh() or seekBar
  local range = seekBar.range
  if range and count == focus_count then
    sf.speak(string.format('%d s', math.floor(range.current / 1000)), { interrupt = true })
  end
end

-- Returns false when the focus isn't on a message row at all, so the gesture falls through
-- instead of being swallowed on other WhatsApp screens.
local function on_seek_gesture(forward)
  local item = sf.screen.focused()
  local list = item and list_of(item)
  if not list then
    return false
  end
  sf.setTimeout(seek, 0, item, list, forward, focus_count)
end

sf.onCommand('audioForward', function() return on_seek_gesture(true) end)
sf.onCommand('audioBackward', function() return on_seek_gesture(false) end)

local SKIPPED_BUTTONS = {
  name_in_group = true, contact_photo_view = true, url_layout = true, poll_option_vote_checkbox = true,
  info = true,
}

local function title_of(button)
  local id = short_id(button)
  if id == 'bubble_quoted_message_frame' then
    return tr('Go to replied message')
  elseif id == 'reactions_bubble_layout' then
    return tr('View reactions')
  elseif id == 'link_preview_frame' then
    return tr('Open link')
  elseif id == 'poll_option_main_layout' then
    return tr('Vote') .. ': ' .. label_of(button)
  elseif id == 'polls_main_layout' or id == 'image' then
    local label = label_of(button)
    return label:lower() == 'enlarge photo' and label or ''
  elseif id == 'control_btn' then
    return (button.className or ''):sub(-11) == 'ImageButton' and label_of(button) or tr('Download')
  elseif SKIPPED_BUTTONS[id] then
    return ''
  end
  local label = label_of(button)
  return label:find('^https?://') and tr('Open link') or label
end

sf.onActions(function(item)
  if not list_of(item) then
    return
  end
  local actions, titles = {}, {}
  for _, button in ipairs(item:findAll({ clickable = true }, MAX_BUTTONS)) do
    if button ~= item and not button:find('group_profile_initials') and not button:find('group_profile_pic') then
      local title = title_of(button)
      if title ~= '' and not titles[title] then
        titles[title] = true
        actions[#actions + 1] = { title = title, run = function() button:click() end }
      end
    end
  end
  return actions
end)
-- SandFly signature: MEQCICaTiN1Cw99uKxqcNUQD/682sDTsIxi7cF56q7FyVGAIAiAChEpdRNN+nLb+JBTb02rG0BCuoVw+Wa5i2+yorrx1MQ==
