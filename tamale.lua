--[[
Copyright (c) 2010 Scott Vokes <vokes.s@gmail.com>
 
Permission is hereby granted, free of charge, to any person
obtaining a copy of this software and associated documentation
files (the "Software"), to deal in the Software without
restriction, including without limitation the rights to use,
copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following
conditions:
 
The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.
 
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.
--]]


-- Depenedencies
local assert, getmetatable, ipairs, pairs, pcall, setmetatable, type =
   assert, getmetatable, ipairs, pairs, pcall, setmetatable, type
local concat, insert, sort = table.concat, table.insert, table.sort

local function trace(...) print(string.format(...)) end

---TAble-MAtching Lua Extension.
module("tamale")

VERSION = "1.2.1"

DEBUG = false                   --Set to true to enable traces.

local function sentinel(descr)
   return setmetatable({}, { __tostring=function() return descr end })
end

local VAR, NIL = sentinel("[var]"), sentinel("[nil]")
local function is_var(t) return getmetatable(t) == VAR end


---Mark a string in a match pattern as a variable key.
-- (You probably want to alias this locally to something short.)
-- Any variables beginning with _ are ignored.
-- @usage { "extract", {var"_", var"_", var"third", var"_" } }
-- @usage A variable named "..." captures subsequent array-portion values.
function var(name)
   assert(type(name) == "string", "Variable name must be string")
   local ignore = (name:sub(1, 1) == "_")
   local rest = (name == "...")
   return setmetatable( { name=name, ignore=ignore, rest=rest }, VAR)
end


---Treat a value as a pattern, rather than a string literal.
-- Returns a function closure that calls :match against the input
-- (for matching via pattern strings, LPEG patterns, etc.), rather
-- than comparing via ==. This would probably be locally aliased,
-- and used like { P"num %d+", handler }.
function P(str)
   return function(v) return v:match(str) end
end


---Default hook for match failure.
-- @param val The unmatched value.
function match_fail(val)
   return false, "Match failed", val
end


-- Key-weak cache for table counts, since #t only gives the
-- length of the array portion, and otherwise, values with extra
-- non-numeric keys can match rows that do not have them.
local counts = setmetatable({}, { __mode="k"})

local function get_count(t)
   local v = counts[t]
   if not v then
      v = 0
      for k in pairs(t) do v = v + 1 end
      counts[t] = v
   end
   return v
end


-- Structurally match val against a pattern, setting variables in the
-- pattern to the corresponding values in val, and recursively
-- unifying table fields. String patterns are matched against value
-- strings, adding any captures to the environment's array.
local function unify(pat, val, env, ids, row)
   local pt, vt = type(pat), type(val)
   if pt == "table" then
      if is_var(pat) then
         local cur = env[pat.name]
         if cur and cur ~= val and not pat.ignore then return false end
         env[pat.name] = val
         return env
      end
      if vt ~= "table" then return false end
      if ids[pat] and pat ~= val then --compare by pointer equality
         return false
      else
         for k,v in pairs(pat) do
            if not unify(v, val[k], env, ids, row) then return false end
         end
      end
      if not row.partial then  --make sure val doesn't have extra fields
         if get_count(pat) ~= get_count(val) then return false end
      elseif row.rest then      --save V"..." captures
         local rest = {}
         for i=row.rest,#val do rest[#rest+1] = val[i] end
         env['...'] = rest
      end
      return env
   elseif pt == "function" then
      local cs = { pat(val) }
      if #cs == 0 then return false end
      for _,c in ipairs(cs) do env[#env+1] = c end
      return env 
   else                         --just compare as literals
      return pat == val and env or false
   end
end


-- Replace any variables in the result with their captures.
local function substituted(res, u)
   local r = {}
   if is_var(res) then return u[res.name] end
   for k,v in pairs(res) do
      if type(v) == "table" then
         if is_var(v) then r[k] = u[v.name] else r[k] = substituted(v, u) end
      else
         r[k] = v
      end
   end
   return r
end


-- Return (or execute) the result, substituting any vars present.
local function do_res(res, u, has_vars)
   local t = type(res)
   if t == "function" then
      return res(u)
   elseif t == "table" and has_vars then
      return substituted(res, u), u
   end
   return res, u
end


local function append(t, key, val)
   local arr = t[key] or {}
   arr[#arr+1] = val; t[key] = arr
end


local function has_vars(res)
   if type(res) ~= "table" then return false end
   if is_var(res) then return true end
   for k,v in pairs(res) do
      if type(v) == "table" then
         if is_var(v) or has_vars(v) then return true end
      end
   end
   return false
end


-- If the list of row IDs didn't exist when the var row was
-- indexed (and thus didn't get added), add it here.
local function prepend_vars(vars, lists)
   for i=#vars,1,-1 do
      local vid = vars[i]
      for k,l in pairs(lists) do
         if l[1] > vid then insert(l, 1, vid) end
      end
   end
end

local function indexable(v)
   return not is_var(v) and type(v) ~= "function"
end

-- Index each literal pattern and pattern table's first value (t[1]). 
-- Also, add insert patterns with vars or string patterns in the
-- appropriate place(s).
local function index_spec(spec)
   local ls, ts = {}, {}        --literals and tables
   local lni, tni = {}, {}      --non-indexable fields for same
   local vrs = {}               --rows with vars in the result

   for id, row in ipairs(spec) do
      local pat, res = row[1], row[2]
      local pt = type(pat)
      if not indexable(pat) then     --could match anything
         lni[#lni+1] = id; tni[#tni+1] = id
      elseif pt == "table" then
         local v = pat[1] or NIL
         if not indexable(v) then    --goes in every index
            for k in pairs(ts) do append(ts, k, id) end
            tni[#tni+1] = id
         else
            append(ts, v, id)
         end

         for i,v in ipairs(pat) do --check for special V"..." var
            if is_var(v) and v.rest then
               row.partial = true; row.rest = i; break
            end
         end
      else
         append(ls, pat, id)
      end
      if has_vars(res) then vrs[id] = true end
   end

   prepend_vars(lni, ls)
   prepend_vars(tni, ts)
   ls[VAR] = lni; ts[VAR] = tni
   return { ls=ls, ts=ts, vrs=vrs }
end


-- Get the appropriate list of rows to check (if any).
local function check_index(spec, t, idx)
   local tt = type(t)
   if tt == "table" then
      local key = t[1] or NIL
      local ts = idx.ts
      return ts[key] or ts[VAR]
   else
      local ls = idx.ls
      return ls[t] or ls[VAR]
   end
end


---Return a matcher function for a given specification. When the
-- function is called on one or more values, its first argument is
-- tested in order against every row that could possibly match it,
-- selecting the relevant result (if any) or returning the values
-- (false, "Match failed", val).
-- If the result is a function, it is called with an environment table
-- containing any captures and any subsequent
-- arguments passed to the matcher function (in env.args).
--@param spec A list of rows, where each row is of the form
--  { pattern, result, [when=capture_test_fun(cs)] }. Each
--  table pattern is indexed by pattern[1].
--@usage spec.ids: An optional list of table values that should be
--  compared by identity, not structure. If any empty tables are
--  being used as a sentinel value (e.g. "MAGIC_ID = {}"), list
--  them here.
--@usage spec.debug: Turn on debugging traces for the matcher.
function matcher(spec)
   local debug = spec.debug or DEBUG
   local ids = {}
   if spec.ids then
      for _,id in ipairs(spec.ids) do ids[id] = true end
   end

   local idx = index_spec(spec)
   local vrs = idx.vrs  --variable rows

   return
   function (t, ...)
      local rows = check_index(spec, t, idx)
      if debug then
         trace(" -- Checking rows: %s", concat(rows, ", "))
      end

      for _,id in ipairs(rows) do
         local row = spec[id]
         local pat, res, when = row[1], row[2], row.when
         local args = { ... }

         local u = unify(pat, t, { args=args }, ids, row)
         if debug then
            trace("-- Trying row %d...%s", id, u and "matched" or "failed")
         end
         
         if u then
            u.input = t         --whole matched value
            if when then
               local ok, val = pcall(when, u)
               if debug then trace("-- Running when(captures) check...%s",
                                   ok and "matched" or "failed")
               end
               if ok and val then
                  return do_res(res, u, vrs[id])
               end
            else
               return do_res(res, u, vrs[id])
            end
         end
      end
      if debug then trace("-- Failed") end
      local fail = spec.fail or match_fail
      return fail(t)
   end         
end
