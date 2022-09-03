nbytes(x::AbstractVector{UInt8}) = length(x)
nbytes(x::String) = filesize(x)
nbytes(x::IOBuffer) = x.size - x.ptr + 1
nbytes(x::IO) = eof(x) ? 0 : bytesavailable(x)

function prepBody(x::RequestBodyType, compress::Bool)
    if x isa String || x isa IOStream
        body = Mmap.mmap(x)
    elseif x isa IOBuffer
        if x.ptr == 1
            body = x.data
        else
            body = x.data[x.ptr:end]
        end
    elseif x isa IO
        body = read(x)
    else
        body = x
    end
    return compress ? transcode(GzipCompressor, body) : body
end

function prepBodyMultipart(x::RequestBodyType, compress::Bool)
    if x isa String
        body = open(x, "r") # need to close later!
    elseif x isa AbstractVector{UInt8}
        body = IOBuffer(x)
    else
        @assert x isa IO
        body = x
    end
    return compress ? GzipCompressorStream(body) : body
end

function putObjectImpl(x::AbstractStore, key::String, in::RequestBodyType;
    multipartThreshold::Int=64_000_000,
    partSize::Int=16_000_000,
    batchSize::Int=defaultBatchSize(),
    allowMultipart::Bool=true,
    compress::Bool=false, kw...)

    N = nbytes(in)
    if N <= multipartThreshold || !allowMultipart
        body = prepBody(in, compress)
        resp = putObject(x, key, body; kw...)
        return Object(x, key, "", etag(HTTP.header(resp, "ETag")), N, "")
    end
    # multipart upload
    uploadState = startMultipartUpload(x, key; kw...)
    url = makeURL(x, key)
    eTags = String[]
    sync = OrderedSynchronizer(1)
    body = prepBodyMultipart(in, compress)
    nTasks = cld(N, partSize)
    nLoops = cld(nTasks, batchSize)
    # while nLoops * batchSize is the *max* # of iterations we'll do
    # if we're compressing, it will likely be much fewer, so we add
    # eof(body) checks to both loops to account for earlier termination
    for j = 1:nLoops
        @sync for i = 1:batchSize
            eof(body) && break
            n = (j - 1) * batchSize + i
            #TODO: we should avoid the extra copies when the input is a Vector{UInt8}
            # currently we wrap it in IOBuffer and then call a plain read on it
            part = read(body, partSize)
            let n=n, part=part
                Threads.@spawn begin
                    eTag = uploadPart(x, url, part, n, uploadState; kw...)
                    let eTag=eTag
                        # we synchronize the eTags here because the order matters
                        # for the final call to completeMultipartUpload
                        put!(() -> push!(eTags, eTag), sync, n)
                    end
                end
            end
        end
        eof(body) && break
    end
    # cleanup body
    if body isa GzipDecompressorStream
        body = body.stream
    end
    if in isa String
        close(body)
    end
    # println("closing multipart")
    # @show eTags
    eTag = completeMultipartUpload(x, url, eTags, uploadState; kw...)
    return Object(x, key, "", eTag, N, "")
end