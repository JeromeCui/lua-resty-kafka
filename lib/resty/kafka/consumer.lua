-- Copyright (C) Dejiang Zhu(doujiang24)


local broker = require "resty.kafka.broker"
local client = require "resty.kafka.client"
local request = require "resty.kafka.request"


local setmetatable = setmetatable
local thread_spawn = ngx.thread.spawn
local timer_at = ngx.timer.at
local ngx_log = ngx.log
local ERR = ngx.ERR
local INFO = ngx.INFO
local DEBUG = ngx.DEBUG
local debug = ngx.config.debug
local pid = ngx.worker.pid
local time = ngx.time
local sleep = ngx.sleep
local ceil = math.ceil
local pairs = pairs


local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end


local _M = { _VERSION = "0.02" }
local mt = { __index = _M }


function _M.new(self, broker_list, consumer_config)
    local opts = producer_config or {}
    local cli = client:new(broker_list, consumer_config)

    local consumer = setmetatable({
        client = cli,
        -- session_timeout = opts.session_timeout or 2000,
        -- rebalance_timeout = opts.rebalance_timeout or 2000,
        -- retry_backoff = opts.retry_backoff or 100,   -- ms
        -- max_retry = opts.max_retry or 3,
        -- required_acks = opts.required_acks or 1,
        -- partitioner = opts.partitioner or default_partitioner,
        -- error_handle = opts.error_handle,
        api_version = opts.api_version or request.API_VERSION_V3,
        -- async = async,
        broker_list = broker_list,
        socket_config = cli.socket_config,
        --ringbuffer = ringbuffer:new(opts.batch_num or 200, opts.max_buffering or 50000),   -- 200, 50K
        --receivebuffer = sendbuffer:new(opts.batch_num or 200, opts.batch_size or 1048576)
    }, mt)

    return consumer
end


local function offset_encode(self, topic, partition_id)
    local req = request:new(request.OffsetRequest,
                            self.client:correlation_id(),
                            self.client.client_id, self.api_version)

    -- replica ID is always -1 for clients
    req:int32(-1)
    -- TopicArray
    req:int32(1)
    -- TopicName
    req:string(topic)
    -- PartitionsArray
    req:int32(1)
    -- PartitionId
    req:int32(partition_id)
    -- Time
    req:int64(-1)
    -- MaxNumberOfOffsets
    if req.api_version == request.API_VERSION_V0 then
      req:int32(1)
    end

    return req
end


local function offset_decode(resp)
    local topic_num = resp:int32()
    local ret = new_tab(0, topic_num)

    for i = 1, topic_num do
        local topic = resp:string()
        local partition_num = resp:int32()

        ret[topic] = {}

        for j = 1, partition_num do
            local partition = resp:int32()
            local errcode = resp:int16()

            local offset_num
            if resp.api_version == request.API_VERSION_V0 then
                offset_num = resp:int32()
            else -- V1
                _ = _resp:int64() -- Timestamp
                offset_num = 1
            end

            offsets = new_tab(offset_num, 0)

            for m = 1, offset_num do
                offsets[m] = tonumber(resp:int64())
            end

            ret[topic][partition] = {
                errcode = errcode,
                offsets = offsets,
            }
        end
    end

    return ret
end


function _M.fetch_offset(self, topic)
    local client = self.client

    local brokers, partitions = client:fetch_metadata(topic)
    if not brokers then
        return nil, partitions
    end

    local offsets = {}
    for partition_id = 0, partitions.num - 1 do
        local broker_conf, err = client:choose_broker(topic, partition_id)
        if not broker_conf then
            return nil, err
        end

        local bk, err = broker:new(broker_conf.host, broker_conf.port, self.socket_config)
        if not bk then
            return nil, err
        end

        local req = offset_encode(self, topic, partition_id)

        local resp, err = bk:send_receive(req)

        if not resp then
            return nil, err
        end

        local r = offset_decode(resp)

        offsets[partition_id] = r[topic][partition_id].offsets[1]
    end

    return offsets
end


local function fetch_encode(self, topic, partition_id, offset)
    local req = request:new(request.FetchRequest,
                            self.client:correlation_id(),
                            self.client.client_id, self.api_version)

    -- replica ID is always -1 for clients
    req:int32(-1)
    -- MaxWaitTime
    req:int32(1000 * 2)
    -- MinBytes
    req:int32(1)
    -- MaxBytes
    if req.api_version == request.API_VERSION_V3 then
      req:int32(1)
    end

    -- TopicsArray
    req:int32(1)
    -- TopicName
    req:string(topic)

    -- PartitionsArray
    req:int32(1)
    -- PartitionID
    req:int32(partition_id)
    -- Offset
    req:int64(offset)
    -- MaxBytes
    req:int32(1024 * 10)

    return req
end


local function fetch_decode(resp, offset)
    local api_version = resp.api_version

    if api_version ~= request.API_VERSION_V0 then -- V1, V2 or V3
         _ = resp:int32() -- throttle_time_ms
    end

    local topic_num = resp:int32()
    local ret = new_tab(0, topic_num)

    for i = 1, topic_num do
        local topic = resp:string()
        local partition_num = resp:int32()

        ret[topic] = {}

        for j = 1, partition_num do
            local partition = resp:int32()
            local errcode = resp:int16()
            local high = tonumber(resp:int64())

            local messages, new_offset = resp:message_set(offset)
            ret[topic][partition] = {
                errcode = errcode,
                highwatermarkoffset = high,
                messages = messages,
                new_offset = tonumber(new_offset),
            }
        end
    end

    return ret
end


local function fetch_single_partition(self, topic, partition_id, offset)
    local client = self.client

    local broker_conf, err = client:choose_broker(topic, partition_id)
    if not broker_conf then
        return nil, err
    end

    local bk, err = broker:new(broker_conf.host, broker_conf.port, self.socket_config)
    if not bk then
        return nil, err
    end

    local req = fetch_encode(self, topic, partition_id, offset)
    local resp, err = bk:send_receive(req)

    if not resp then
        return nil, err
    end

    return fetch_decode(resp, offset)
end


local function merge(a1, a2)
    local s = #a1
    for i = 1, #a2 do
        a1[s + i] = a2[i]
    end
end


function _M.fetch(self, topic, offsets)
    local cos = {}
    for partition_id, offset in pairs(offsets) do
        cos[partition_id] = thread_spawn(fetch_single_partition, self, topic, partition_id, offset)
    end

    local ret = {}
    for partition_id, co in pairs(cos) do
        local ok, res = ngx.thread.wait(co)
        if ok and res then
            local partition = res[topic][partition_id]
            local messages = partition.messages
            offsets[partition_id] = partition.new_offset

            if messages and #messages > 0 then
                merge(ret, messages)
            end
        end
    end

    return ret, offsets
end


return _M
