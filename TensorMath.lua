local wrap = require 'cwrap'

local interface = wrap.CInterface.new()
local method = wrap.CInterface.new()

interface:print('/* WARNING: autogenerated file */')
interface:print('')
interface:print('#include "THC.h"')
interface:print('#include "luaT.h"')
interface:print('#include "torch/utils.h"')
interface:print('')
interface:print('')

interface:print([[
static int torch_isnonemptytable(lua_State *L, int idx)
{
  int empty;
  if (!lua_istable(L, idx)) return 0;

  lua_rawgeti(L, idx, 1);
  empty = lua_isnil(L, -1);
  lua_pop(L, 1);
  return !empty;
}
]])

-- Lua 5.2 compatibility
local unpack = unpack or table.unpack

-- specific to CUDA
local typenames = {'CudaByteTensor',
                   'CudaCharTensor',
                   'CudaShortTensor',
                   'CudaIntTensor',
                   'CudaLongTensor',
                   'CudaTensor',
                   'CudaDoubleTensor'}

for _, typename in ipairs(typenames) do
-- cut and paste from wrap/types.lua
wrap.types[typename] = {

   helpname = function(arg)
      if arg.dim then
         return string.format('%s~%dD', typename, arg.dim)
      else
         return typename
      end
   end,

   declare = function(arg)
      local txt = {}
      table.insert(txt, string.format("TH%s *arg%d = NULL;", typename, arg.i))
      if arg.returned then
         table.insert(txt, string.format("int arg%d_idx = 0;", arg.i));
      end
      return table.concat(txt, '\n')
   end,

   check = function(arg, idx)
      if arg.dim then
         return string.format('(arg%d = luaT_toudata(L, %d, "torch.%s")) && (arg%d->nDimension == %d)', arg.i, idx, typename, arg.i, arg.dim)
      else
         return string.format('(arg%d = luaT_toudata(L, %d, "torch.%s"))', arg.i, idx, typename)
      end
   end,

   read = function(arg, idx)
      if arg.returned then
         return string.format("arg%d_idx = %d;", arg.i, idx)
      end
   end,

   init = function(arg)
      if type(arg.default) == 'boolean' then
         return string.format('arg%d = TH%s_new(cutorch_getstate(L));', arg.i, typename)
      elseif type(arg.default) == 'number' then
         return string.format('arg%d = %s;', arg.i, arg.args[arg.default]:carg())
      else
         error('unknown default tensor type value')
      end
   end,

   carg = function(arg)
      return string.format('arg%d', arg.i)
   end,

   creturn = function(arg)
      return string.format('arg%d', arg.i)
   end,

   precall = function(arg)
      local txt = {}
      if arg.default and arg.returned then
         table.insert(txt, string.format('if(arg%d_idx)', arg.i)) -- means it was passed as arg
         table.insert(txt, string.format('lua_pushvalue(L, arg%d_idx);', arg.i))
         table.insert(txt, string.format('else'))
         if type(arg.default) == 'boolean' then -- boolean: we did a new()
            table.insert(txt, string.format('luaT_pushudata(L, arg%d, "torch.%s");', arg.i, typename))
         else  -- otherwise: point on default tensor --> retain
            table.insert(txt, string.format('{'))
            table.insert(txt, string.format('TH%s_retain(arg%d);', typename, arg.i)) -- so we need a retain
            table.insert(txt, string.format('luaT_pushudata(L, arg%d, "torch.%s");', arg.i, typename))
            table.insert(txt, string.format('}'))
         end
      elseif arg.default then
         -- we would have to deallocate the beast later if we did a new
         -- unlikely anyways, so i do not support it for now
         if type(arg.default) == 'boolean' then
            error('a tensor cannot be optional if not returned')
         end
      elseif arg.returned then
         table.insert(txt, string.format('lua_pushvalue(L, arg%d_idx);', arg.i))
      end
      return table.concat(txt, '\n')
   end,

   postcall = function(arg)
      local txt = {}
      if arg.creturned then
         -- if a tensor is returned by a wrapped C function, the refcount semantics
         -- are ambiguous (transfer ownership vs. shared ownership).
         -- We never actually do this, so lets just not allow it.
         error('a tensor cannot be creturned')
      end
      return table.concat(txt, '\n')
   end
}

wrap.types[typename .. 'Array'] = {

   helpname = function(arg)
                 return string.format('{%s+}', typename)
            end,

   declare = function(arg)
                local txt = {}
                table.insert(txt, string.format('TH%s **arg%d_data = NULL;', typename, arg.i))
                table.insert(txt, string.format('long arg%d_size = 0;', arg.i))
                table.insert(txt, string.format('int arg%d_i = 0;', arg.i))
                return table.concat(txt, '\n')
           end,

   check = function(arg, idx)
              return string.format('torch_isnonemptytable(L, %d)', idx)
         end,

   read = function(arg, idx)
             local txt = {}
             -- Iterate over the array to find its length, leave elements on stack.
             table.insert(txt, string.format('do'))
             table.insert(txt, string.format('{'))
             table.insert(txt, string.format('  arg%d_size++;', arg.i))
             table.insert(txt, string.format('  lua_checkstack(L, 1);'))
             table.insert(txt, string.format('  lua_rawgeti(L, %d, arg%d_size);', idx, arg.i))
             table.insert(txt, string.format('}'))
             table.insert(txt, string.format('while (!lua_isnil(L, -1));'))
             table.insert(txt, string.format('arg%d_size--;', arg.i))
             -- Pop nil element from stack.
             table.insert(txt, string.format('lua_pop(L, 1);'))
             -- Allocate tensor pointers and read values from stack backwards.
             table.insert(txt, string.format('arg%d_data = (TH%s**)THAlloc(arg%d_size * sizeof(TH%s*));', arg.i, typename, arg.i, typename))
             table.insert(txt, string.format('for (arg%d_i = arg%d_size - 1; arg%d_i >= 0; arg%d_i--)', arg.i, arg.i, arg.i, arg.i))
             table.insert(txt, string.format('{'))
             table.insert(txt, string.format('  if (!(arg%d_data[arg%d_i] = luaT_toudata(L, -1, "torch.%s")))', arg.i, arg.i, typename))
             table.insert(txt, string.format('    luaL_error(L, "expected %s in tensor array");', typename))
             table.insert(txt, string.format('  lua_pop(L, 1);'))
             table.insert(txt, string.format('}'))
             table.insert(txt, string.format(''))
             return table.concat(txt, '\n')
          end,

   init = function(arg)
          end,

   carg = function(arg)
             return string.format('arg%d_data,arg%d_size', arg.i, arg.i)
          end,

   creturn = function(arg)
                error('TensorArray cannot be returned.')
             end,

   precall = function(arg)
             end,

   postcall = function(arg)
                 return string.format('THFree(arg%d_data);', arg.i)
              end
}
end

wrap.types.LongArg = {

   vararg = true,

   helpname = function(arg)
      return "(LongStorage | dim1 [dim2...])"
   end,

   declare = function(arg)
      return string.format("THLongStorage *arg%d = NULL;", arg.i)
   end,

   init = function(arg)
      if arg.default then
         error('LongArg cannot have a default value')
      end
   end,

   check = function(arg, idx)
      return string.format("cutorch_islongargs(L, %d)", idx)
   end,

   read = function(arg, idx)
      return string.format("arg%d = cutorch_checklongargs(L, %d);", arg.i, idx)
   end,

   carg = function(arg, idx)
      return string.format('arg%d', arg.i)
   end,

   creturn = function(arg, idx)
      return string.format('arg%d', arg.i)
   end,

   precall = function(arg)
      local txt = {}
      if arg.returned then
         table.insert(txt, string.format('luaT_pushudata(L, arg%d, "torch.LongStorage");', arg.i))
      end
      return table.concat(txt, '\n')
   end,

   postcall = function(arg)
      local txt = {}
      if arg.creturned then
         -- this next line is actually debatable
         table.insert(txt, string.format('THLongStorage_retain(arg%d);', arg.i))
         table.insert(txt, string.format('luaT_pushudata(L, arg%d, "torch.LongStorage");', arg.i))
      end
      if not arg.returned and not arg.creturned then
         table.insert(txt, string.format('THLongStorage_free(arg%d);', arg.i))
      end
      return table.concat(txt, '\n')
   end
}

wrap.types.charoption = {

   helpname = function(arg)
                 if arg.values then
                    return "(" .. table.concat(arg.values, '|') .. ")"
                 end
              end,

   declare = function(arg)
                local txt = {}
                table.insert(txt, string.format("const char *arg%d = NULL;", arg.i))
                if arg.default then
                   table.insert(txt, string.format("char arg%d_default = '%s';", arg.i, arg.default))
                end
                return table.concat(txt, '\n')
           end,

   init = function(arg)
             return string.format("arg%d = &arg%d_default;", arg.i, arg.i)
          end,

   check = function(arg, idx)
              local txt = {}
              local txtv = {}
              table.insert(txt, string.format('(arg%d = lua_tostring(L, %d)) && (', arg.i, idx))
              for _,value in ipairs(arg.values) do
                 table.insert(txtv, string.format("*arg%d == '%s'", arg.i, value))
              end
              table.insert(txt, table.concat(txtv, ' || '))
              table.insert(txt, ')')
              return table.concat(txt, '')
         end,

   read = function(arg, idx)
          end,

   carg = function(arg, idx)
             return string.format('arg%d', arg.i)
          end,

   creturn = function(arg, idx)
             end,

   precall = function(arg)
             end,

   postcall = function(arg)
              end
}

cutorch_state_code = function(varname)
  local txt = {}
  table.insert(txt, 'lua_getglobal(L, "cutorch");')
  table.insert(txt, 'lua_getfield(L, -1, "_state");')
  table.insert(txt, string.format('THCState *%s = lua_touserdata(L, -1);', varname))
  table.insert(txt, 'lua_pop(L, 2);')
  return table.concat(txt, '\n');
end
interface:registerDefaultArgument(cutorch_state_code)
method:registerDefaultArgument(cutorch_state_code)

local function wrap(...)
   local args = {...}

   -- interface
   interface:wrap(...)

   -- method: we override things possibly in method table field
   for _,x in ipairs(args) do
      if type(x) == 'table' then -- ok, now we have a list of args
         for _, arg in ipairs(x) do
            if arg.method then
               for k,v in pairs(arg.method) do
                  if v == 'nil' then -- special case, we erase the field
                     arg[k] = nil
                  else
                     arg[k] = v
                  end
               end
            end
         end
      end
   end
   method:wrap(unpack(args))
end

--
-- Non-CudaTensor type math, since these are less fully implemented than
-- CudaTensor
--

local handledTypenames = {'CudaByteTensor',
                          'CudaCharTensor',
                          'CudaShortTensor',
                          'CudaIntTensor',
                          'CudaLongTensor',
                          'CudaDoubleTensor'}
local handledTypereals = {'unsigned char',
                          'char',
                          'short',
                          'int',
                          'long',
                          'double'}

for k, Tensor in pairs(handledTypenames) do
    local real = handledTypereals[k]

    function interface.luaname2wrapname(self, name)
        return string.format('cutorch_%s_%s', Tensor, name)
    end

    function method.luaname2wrapname(self, name)
        return string.format('m_cutorch_%s_%s', Tensor, name)
    end

    local function cname(name)
        return string.format('TH%s_%s', Tensor, name)
    end

    local function lastdim(argn)
        return function(arg)
            return string.format('TH%s_nDimension(cutorch_getstate(L), %s)',
                                 Tensor, arg.args[argn]:carg())
        end
    end

    local function lastdimarray(argn)
        return function(arg)
            return string.format('TH%s_nDimension(cutorch_getstate(L), arg%d_data[0])',
                                 Tensor, arg.args[argn].i)
        end
    end

    wrap("fill",
         cname("fill"),
         {{name=Tensor, returned=true},
             {name=real}})

    wrap("zero",
         cname("zero"),
         {{name=Tensor, returned=true}})

    wrap("zeros",
         cname("zeros"),
         {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name="LongArg"}})

    wrap("ones",
         cname("ones"),
         {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name="LongArg"}})

    wrap("reshape",
         cname("reshape"),
         {{name=Tensor, default=true, returned=true},
            {name=Tensor},
            {name="LongArg"}})

    wrap("numel",
         cname("numel"),
         {{name=Tensor},
            {name="long", creturned=true}})

    wrap("add",
         cname("add"),
         {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}},
            {name=real}},
         cname("cadd"),
         {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}},
            {name=real, default=1},
            {name=Tensor}})

    wrap("csub",
         cname("sub"),
         {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}},
            {name=real}},
         cname("csub"),
         {{name=Tensor, default=true, returned=true, method={default='nil'}},
            {name=Tensor, method={default=1}},
            {name=real, default=1},
            {name=Tensor}})

    for _, name in ipairs({"cmul", "cpow", "cdiv"}) do
       wrap(name,
            cname(name),
            {{name=Tensor, default=true, returned=true, method={default='nil'}},
               {name=Tensor, method={default=1}},
               {name=Tensor}})
    end

    method:register("m_cutorch_" .. Tensor .. "Math__")
    interface:print(method:tostring())
    method:clearhistory()
    method:registerDefaultArgument(cutorch_state_code)
    interface:register("cutorch_" .. Tensor .. "Math__")

    interface:print(string.format([[
void cutorch_%sMath_init(lua_State *L)
{
  luaT_pushmetatable(L, "torch.%s");

  /* register methods */
  luaL_setfuncs(L, m_cutorch_%sMath__, 0);

  /* register functions into the "torch" field of the tensor metaclass */
  lua_pushstring(L, "torch");
  lua_newtable(L);
  luaL_setfuncs(L, cutorch_%sMath__, 0);
  lua_rawset(L, -3);
  lua_pop(L, 1);
}
]], Tensor, Tensor, Tensor, Tensor))
end


--
-- CudaTensor special handling, since it is more fully implemented
--

local Tensor = "CudaTensor"
local real = "float"

function interface.luaname2wrapname(self, name)
   return string.format('cutorch_%s_%s', Tensor, name)
end

function method.luaname2wrapname(self, name)
    return string.format('m_cutorch_%s_%s', Tensor, name)
end

local function cname(name)
   return string.format('TH%s_%s', Tensor, name)
end

local function lastdim(argn)
   return function(arg)
       return string.format('TH%s_nDimension(cutorch_getstate(L), %s)',
                            Tensor, arg.args[argn]:carg())
   end
end

local function lastdimarray(argn)
   return function(arg)
       return string.format('TH%s_nDimension(cutorch_getstate(L), arg%d_data[0])',
                            Tensor, arg.args[argn].i)
   end
end

wrap("zero",
     cname("zero"),
     {{name=Tensor, returned=true}})

wrap("fill",
     cname("fill"),
     {{name=Tensor, returned=true},
         {name=real}})

wrap("zeros",
     cname("zeros"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
        {name="LongArg"}})

   wrap("ones",
        cname("ones"),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
           {name="LongArg"}})

   wrap("reshape",
        cname("reshape"),
        {{name=Tensor, default=true, returned=true},
           {name=Tensor},
           {name="LongArg"}})

   wrap("numel",
        cname("numel"),
        {{name=Tensor},
           {name="long", creturned=true}})

wrap("add",
     cname("add"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
      {name=Tensor, method={default=1}},
      {name=real}},
     cname("cadd"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
        {name=Tensor, method={default=1}},
        {name=real, default=1},
        {name=Tensor}})


wrap("csub",
     cname("sub"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
      {name=Tensor, method={default=1}},
      {name=real}},
     cname("csub"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
        {name=Tensor, method={default=1}},
        {name=real, default=1},
        {name=Tensor}})

wrap("mul",
     cname("mul"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
        {name=Tensor, method={default=1}},
        {name=real}})

wrap("div",
     cname("div"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
        {name=Tensor, method={default=1}},
        {name=real}})

for _, name in ipairs({"cmul", "cpow", "cdiv"}) do
  wrap(name,
       cname(name),
       {{name=Tensor, default=true, returned=true, method={default='nil'}},
          {name=Tensor, method={default=1}},
        {name=Tensor}})
end

wrap("addcmul",
     cname("addcmul"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
        {name=Tensor, method={default=1}},
        {name=real, default=1},
        {name=Tensor},
        {name=Tensor}})

wrap("addcdiv",
     cname("addcdiv"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
        {name=Tensor, method={default=1}},
        {name=real, default=1},
        {name=Tensor},
        {name=Tensor}})

wrap("maskedFill",
     cname("maskedFill"),
     {{name=Tensor, returned=true, method={default='nil'}},
      {name=Tensor},
      {name=real}})

wrap("maskedCopy",
     cname("maskedCopy"),
     {{name=Tensor, returned=true, method={default='nil'}},
	{name=Tensor},
	{name=Tensor}})

wrap("maskedSelect",
     cname("maskedSelect"),
     {{name=Tensor, returned=true, default=true},
      {name=Tensor},
      {name=Tensor}})

wrap("gather",
     cname("gather"),
     {{name=Tensor, default=true, returned=true,
       init=function(arg)
               return table.concat(
                  {
                     arg.__metatable.init(arg),
                     string.format("TH%s_checkGPU(cutorch_getstate(L), 1, %s);",
                                   Tensor, arg.args[4]:carg()),
                     string.format("TH%s_resizeAs(cutorch_getstate(L), %s, %s);", Tensor, arg:carg(), arg.args[4]:carg()),
                  }, '\n')
            end
      },
      {name=Tensor},
      {name="index"},
      {name=Tensor}})

wrap("scatter",
     cname("scatter"),
     {{name=Tensor, returned=true},
      {name="index"},
      {name=Tensor},
      {name=Tensor}},
     cname("scatterFill"),
     {{name=Tensor, returned=true},
      {name="index"},
      {name=Tensor},
      {name=real}})

wrap("sort",
     cname("sort"),
     {{name=Tensor, default=true, returned=true},
        {name=Tensor, default=true, returned=true, noreadadd=true},
        {name=Tensor},
        {name="index", default=lastdim(3)},
        {name="boolean", default=0}})

wrap("topk",
     cname("topk"),
     {{name=Tensor, default=true, returned=true},
        {name=Tensor, default=true, returned=true, noreadadd=true},
        {name=Tensor},
        {name="long", default=1},
        {name="index", default=lastdim(3)},
        {name="boolean", default=0},
        {name="boolean", default=0}})

do
   local Tensor = Tensor
   local real = real
   wrap("mv",
        cname("addmv"),
        {{name=Tensor, default=true, returned=true, method={default='nil'},
          init=function(arg)
             return table.concat(
                {
                   arg.__metatable.init(arg),
                   string.format("TH%s_checkGPU(cutorch_getstate(L), 1, %s);",
                                 Tensor, arg.args[5]:carg()),
                   string.format("TH%s_resize1d(cutorch_getstate(L), %s, %s->size[0]);", Tensor, arg:carg(), arg.args[5]:carg())
                }, '\n')
          end,
          precall=function(arg)
             return table.concat(
                {
                   string.format("TH%s_zero(cutorch_getstate(L), %s);", Tensor, arg:carg()),
                   arg.__metatable.precall(arg)
                }, '\n')
          end
         },
           {name=real, default=1, invisible=true},
           {name=Tensor, default=1, invisible=true},
           {name=real, default=1, invisible=true},
           {name=Tensor, dim=2},
           {name=Tensor, dim=1}}
   )

   wrap("mm",
        cname("addmm"),
        {{name=Tensor, default=true, returned=true, method={default='nil'},
          init=function(arg)
             return table.concat(
                {
                   arg.__metatable.init(arg),
                   string.format("TH%s_checkGPU(cutorch_getstate(L), 2, %s, %s);",
                                 Tensor, arg.args[5]:carg(), arg.args[6]:carg()),
                   string.format("TH%s_resize2d(cutorch_getstate(L), %s, %s->size[0], %s->size[1]);",
                                 Tensor, arg:carg(), arg.args[5]:carg(), arg.args[6]:carg())
                }, '\n')
          end,
         },
           {name=real, default=0, invisible=true},
           {name=Tensor, default=1, invisible=true},
           {name=real, default=1, invisible=true},
           {name=Tensor, dim=2},
           {name=Tensor, dim=2}}
   )

   wrap("bmm",
        cname("baddbmm"),
        {{name=Tensor, default=true, returned=true, method={default='nil'},
          init=function(arg)
             return table.concat(
                {
                   arg.__metatable.init(arg),
                   string.format("TH%s_checkGPU(cutorch_getstate(L), 2, %s, %s);",
                                 Tensor, arg.args[5]:carg(), arg.args[6]:carg()),
                   string.format("TH%s_resize3d(cutorch_getstate(L), %s, %s->size[0], %s->size[1], %s->size[2]);",
                                 Tensor, arg:carg(), arg.args[5]:carg(), arg.args[5]:carg(), arg.args[6]:carg())
                }, '\n')
          end,
         },
           {name=real, default=0, invisible=true},
           {name=Tensor, default=1, invisible=true},
           {name=real, default=1, invisible=true},
           {name=Tensor, dim=3},
           {name=Tensor, dim=3}}
   )

   wrap("ger",
        cname("addr"),
        {{name=Tensor, default=true, returned=true, method={default='nil'},
          init=function(arg)
             return table.concat(
                {
                   arg.__metatable.init(arg),
                   string.format("TH%s_checkGPU(cutorch_getstate(L), 2, %s, %s);",
                                 Tensor, arg.args[5]:carg(), arg.args[6]:carg()),
                   string.format("TH%s_resize2d(cutorch_getstate(L), %s, %s->size[0], %s->size[0]);", Tensor, arg:carg(), arg.args[5]:carg(), arg.args[6]:carg())
                }, '\n')
          end,
          precall=function(arg)
             return table.concat(
                {
                   string.format("TH%s_zero(cutorch_getstate(L), %s);", Tensor, arg:carg()),
                   arg.__metatable.precall(arg)
                }, '\n')
          end
         },
           {name=real, default=1, invisible=true},
           {name=Tensor, default=1, invisible=true},
           {name=real, default=1, invisible=true},
           {name=Tensor, dim=1},
           {name=Tensor, dim=1}}
   )

   for _,f in ipairs({
         {name="addmv",   dim1=1, dim2=2, dim3=1},
         {name="addmm",   dim1=2, dim2=2, dim3=2},
         {name="addr",    dim1=2, dim2=1, dim3=1},
         {name="baddbmm", dim1=3, dim2=3, dim3=3},
         {name="addbmm",  dim1=2, dim2=3, dim3=3},
                     }
   ) do

      interface:wrap(f.name,
                     cname(f.name),
                     {{name=Tensor, default=true, returned=true},
                        {name=real, default=1},
                        {name=Tensor, dim=f.dim1},
                        {name=real, default=1},
                        {name=Tensor, dim=f.dim2},
                        {name=Tensor, dim=f.dim3}})

      -- there is an ambiguity here, hence the more complicated setup
      method:wrap(f.name,
                  cname(f.name),
                  {{name=Tensor, returned=true, dim=f.dim1},
                     {name=real, default=1, invisible=true},
                     {name=Tensor, default=1, dim=f.dim1},
                     {name=real, default=1},
                     {name=Tensor, dim=f.dim2},
                     {name=Tensor, dim=f.dim3}},
                  cname(f.name),
                  {{name=Tensor, returned=true, dim=f.dim1},
                     {name=real},
                     {name=Tensor, default=1, dim=f.dim1},
                     {name=real},
                     {name=Tensor, dim=f.dim2},
                     {name=Tensor, dim=f.dim3}})
   end
end

wrap("dot",
     cname("dot"),
     {{name=Tensor},
      {name=Tensor},
      {name=real, creturned=true}})

wrap("sum",
     cname("sumall"),
     {{name=Tensor},
        {name=real, creturned=true}},
     cname("sum"),
     {{name=Tensor, default=true, returned=true},
        {name=Tensor},
        {name="index"}})

for _, name in ipairs({"cumsum", "cumprod"}) do
  wrap(name,
       cname(name),
       {{name=Tensor, default=true, returned=true},
        {name=Tensor},
        {name="index", default=1}})
end

wrap("prod",
     cname("prodall"),
     {{name=Tensor},
        {name=real, creturned=true}},
     cname("prod"),
     {{name=Tensor, default=true, returned=true},
        {name=Tensor},
        {name="index"}})

for _,name in ipairs({"min", "max"}) do
   wrap(name,
        cname(name .. "all"),
        {{name=Tensor},
           {name=real, creturned=true}},
        cname(name),
        {{name=Tensor, default=true, returned=true},
           {name=Tensor, default=true, returned=true},
           {name=Tensor},
           {name="index"}})
end

for _,name in ipairs({"cmin", "cmax"}) do
   wrap(name,
        cname(name),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor, method={default=1}},
         {name=Tensor}},
        cname(name .. "Value"),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor, method={default=1}},
         {name=real}})
end

wrap("cross",
cname("cross"),
    {{name=Tensor, default=true, returned=true},
     {name=Tensor},
     {name=Tensor},
     {name="index", default=0}})

wrap("tril",
     cname("tril"),
     {{name=Tensor, default=true, returned=true},
      {name=Tensor},
      {name="int", default=0}})

wrap("triu",
     cname("triu"),
     {{name=Tensor, default=true, returned=true},
      {name=Tensor},
      {name="int", default=0}})

for _,name in ipairs({"log", "log1p", "exp",
                      "cos", "acos", "cosh",
                      "sin", "asin", "sinh",
                      "tan", "atan", "tanh",
                      "sqrt", "rsqrt", "sigmoid",
                      "cinv", "ceil", "floor",
                      "neg", "abs", "sign",
                      "round", "trunc", "frac"}) do

   wrap(name,
        cname(name),
        {{name=Tensor, default=true, returned=true, method={default='nil'}},
         {name=Tensor, method={default=1}}})

end

wrap("atan2",
     cname("atan2"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
      {name=Tensor, method={default=1}},
      {name=Tensor}}
)

wrap("lerp",
     cname("lerp"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
      {name=Tensor, method={default=1}},
      {name=Tensor},
      {name=real}}
)

wrap("pow",
     cname("pow"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
      {name=Tensor, method={default=1}},
      {name=real}},
     cname("tpow"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
      {name = real},
      {name=Tensor, method={default=1}}})

wrap("rand",
     cname("rand"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
      {name="LongArg"}})

wrap("randn",
     cname("randn"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
      {name="LongArg"}})

wrap("multinomial",
     cname("multinomial"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
        {name=Tensor},
        {name="int"},
        {name="boolean", default=false}})

wrap("clamp",
     cname("clamp"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
      {name=Tensor, default=1},
      {name=real},
      {name=real}})

for _,name in pairs({'lt','gt','le','ge','eq','ne'}) do
   wrap(name,
        cname(name .. 'Value'),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor},
         {name=real}},
        cname(name .. 'Tensor'),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor},
         {name=Tensor}})
end

for _,name in pairs({'all', 'any'}) do
  wrap(name,
       cname('logical' .. name),
       {{name=Tensor},
        {name="boolean", creturned=true}})
end

wrap("cat",
     cname("cat"),
     {{name=Tensor, default=true, returned=true},
      {name=Tensor},
      {name=Tensor},
      {name="index", default=lastdim(2)}},
     cname("catArray"),
     {{name=Tensor, default=true, returned=true},
      {name=Tensor .. "Array"},
      {name="index", default=lastdimarray(2)}})

for _,f in ipairs({{name='geometric'},
                   {name='bernoulli', a=0.5}}) do

   wrap(f.name,
        cname(f.name),
        {{name=Tensor, returned=true},
         {name=real, default=f.a}})
end

for _,f in ipairs({{name='uniform', a=0, b=1},
                   {name='normal', a=0, b=1},
                   {name='cauchy', a=0, b=1},
                   {name='logNormal', a=1, b=2}}) do

   wrap(f.name,
        cname(f.name),
        {{name=Tensor, returned=true},
         {name=real, default=f.a},
         {name=real, default=f.b}})
end

for _,f in ipairs({{name='exponential'}}) do

   wrap(f.name,
        cname(f.name),
        {{name=Tensor, returned=true},
         {name=real, default=f.a}})
end

for _,name in ipairs({"gesv","gels"}) do
   wrap(name,
        cname(name),
        {{name=Tensor, returned=true},
         {name=Tensor, returned=true},
         {name=Tensor},
         {name=Tensor}},
        cname(name),
        {{name=Tensor, default=true, returned=true, invisible=true},
         {name=Tensor, default=true, returned=true, invisible=true},
         {name=Tensor},
         {name=Tensor}})
end

wrap("symeig",
     cname("syev"),
     {{name=Tensor, returned=true},
      {name=Tensor, returned=true},
      {name=Tensor},
      {name='charoption', values={'N', 'V'}, default='N'},
      {name='charoption', values={'U', 'L'}, default='U'}},
     cname("syev"),
     {{name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor},
      {name='charoption', values={'N', 'V'}, default='N'},
      {name='charoption', values={'U', 'L'}, default='U'}})

wrap("eig",
     cname("geev"),
     {{name=Tensor, returned=true},
      {name=Tensor, returned=true},
      {name=Tensor},
      {name='charoption', values={'N', 'V'}, default='N'}},
     cname("geev"),
     {{name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor},
      {name='charoption', values={'N', 'V'}, default='N'}})

wrap("svd",
     cname("gesvd"),
     {{name=Tensor, returned=true},
      {name=Tensor, returned=true},
      {name=Tensor, returned=true},
      {name=Tensor},
      {name='charoption', values={'A', 'S'}, default='S'}},
     cname("gesvd"),
     {{name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor},
      {name='charoption', values={'A', 'S'}, default='S'}})

wrap("inverse",
     cname("getri"),
     {{name=Tensor, returned=true},
      {name=Tensor}},
     cname("getri"),
     {{name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor}})

wrap("potri",
     cname("potri"),
     {{name=Tensor, returned=true},
      {name=Tensor}},
     cname("potri"),
     {{name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor}})

wrap("potrf",
     cname("potrf"),
     {{name=Tensor, returned=true},
      {name=Tensor}},
     cname("potrf"),
     {{name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor}})

wrap("potrs",
     cname("potrs"),
     {{name=Tensor, returned=true},
      {name=Tensor},
      {name=Tensor}},
     cname("potrs"),
     {{name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor},
      {name=Tensor}})

wrap("qr",
     cname("qr"),
     {{name=Tensor, returned=true},
      {name=Tensor, returned=true},
      {name=Tensor}},
     cname("qr"),
     {{name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor, default=true, returned=true, invisible=true},
      {name=Tensor}})

wrap("mean",
     cname("meanall"),
     {{name=Tensor},
      {name=real, creturned=true}},
     cname("mean"),
     {{name=Tensor, default=true, returned=true},
      {name=Tensor},
      {name="index"}})

for _,name in ipairs({"var", "std"}) do
   wrap(name,
        cname(name .. "all"),
        {{name=Tensor},
         {name=real, creturned=true}},
        cname(name),
        {{name=Tensor, default=true, returned=true},
         {name=Tensor},
         {name="index"},
         {name="boolean", default=false}})
end

wrap("norm",
     cname("normall"),
     {{name=Tensor},
      {name=real, default=2},
      {name=real, creturned=true}},
     cname("norm"),
     {{name=Tensor, default=true, returned=true},
      {name=Tensor},
      {name=real},
      {name="index"}})

wrap("renorm",
     cname("renorm"),
     {{name=Tensor, default=true, returned=true, method={default='nil'}},
      {name=Tensor, method={default=1}},
      {name=real},
      {name="index"},
      {name=real}})

wrap("dist",
     cname("dist"),
     {{name=Tensor},
      {name=Tensor},
      {name=real, default=2},
      {name=real, creturned=true}})

wrap("squeeze",
     cname("squeeze"),
     {{name=Tensor, default=true, returned=true, postcall=function(arg)
          local txt = {}
          if arg.returned then
             table.insert(txt, string.format('if(arg%d->nDimension == 1 && arg%d->size[0] == 1)', arg.i, arg.i)) -- number
             table.insert(txt, string.format('lua_pushnumber(L, (lua_Number)(THCudaTensor_get1d(cutorch_getstate(L), arg%d, 0)));', arg.i))
          end
          return table.concat(txt, '\n')
     end},
      {name=Tensor}},
     cname("squeeze1d"),
     {{name=Tensor, default=true, returned=true,
       postcall=
          function(arg)
             local txt = {}
             if arg.returned then
                table.insert(txt, string.format('if(!hasdims && arg%d->nDimension == 1 && arg%d->size[0] == 1)', arg.i, arg.i)) -- number
                table.insert(txt, string.format('lua_pushnumber(L, (lua_Number)(THCudaTensor_get1d(cutorch_getstate(L), arg%d, 0)));}', arg.i))
             end
             return table.concat(txt, '\n')
          end},

      {name=Tensor,
       precall=
          function(arg)
             return string.format('{int hasdims = arg%d->nDimension > 1;', arg.i)
          end},
      {name="index"}})

method:register("m_cutorch_" .. Tensor .. "Math__")
interface:print(method:tostring())
method:clearhistory()
interface:register("cutorch_" .. Tensor .. "Math__")

interface:print(string.format([[
void cutorch_%sMath_init(lua_State *L)
{
  luaT_pushmetatable(L, "torch.%s");

  /* register methods */
  luaL_setfuncs(L, m_cutorch_%sMath__, 0);

  /* register functions into the "torch" field of the tensor metaclass */
  lua_pushstring(L, "torch");
  lua_newtable(L);
  luaL_setfuncs(L, cutorch_%sMath__, 0);
  lua_rawset(L, -3);
  lua_pop(L, 1);
}
]], Tensor, Tensor, Tensor, Tensor))

interface:tofile(arg[1])
