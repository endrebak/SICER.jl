using DataFrames, CSV, MultipleTesting, Statistics


include("natsort.jl")
include("statistics.jl")
include("parse_args.jl")

include("statistics.jl")



# chromsizes = Dict("chr1" => 249250621,
#                   "chr2" => 243199373,
#                   "chr3" => 198022430,
#                   "chr4" => 191154276,
#                   "chr5" => 180915260,
#                   "chr6" => 171115067,
#                   "chr7" => 159138663,
#                   "chrX" => 155270560,
#                   "chr8" => 146364022,
#                   "chr9" => 141213431,
#                   "chr10" => 135534747,
#                   "chr11" => 135006516,
#                   "chr12" => 133851895,
#                   "chr13" => 115169878,
#                   "chr14" => 107349540,
#                   "chr15" => 102531392,
#                   "chr16" => 90354753,
#                   "chr17" => 81195210,
#                   "chr18" => 78077248,
#                   "chr20" => 63025520,
#                   "chrY" => 59373566,
#                   "chr19" => 59128983,
#                   "chr22" => 51304566,
#                   "chr21" => 48129895,
#                   "chrM" => 16571)


function bin_positions(bdf, half_fragment_size, chromsizes)

    chromosome = bdf[1, :Chromosome]

    sort!(bdf[:, [2,3]], [:Start, :End])

    strand = bdf[:Strand][1]

    if strand == "+"
        vals = bdf[2] .+ half_fragment_size
    else
        vals = bdf[3] .- half_fragment_size
    end

    vals = [i - rem(i, 200) for i in vals]
    df = DataFrame(Bin=vals)

    chromsize = chromsizes[chromosome]
    df = df[df.Bin .< chromsize, :]

end

function df_to_bins(f, args)

    keep_duplicates = args["keep_duplicates"]
    remove_duplicates = !keep_duplicates

    half_fragment_size::Int64 = args["fragment_size"] / 2

    df = file_to_df(f)


    #= remove columns not needed; should not be read in first place
     see github issue: TODO: add =#
    df = df[[1, 2, 3, 6]]

    df = df[in.(df[:Chromosome], (keys(args["chromosome_sizes"]),)), :]

    if remove_duplicates
        df = unique(df)
    end

    # turn positions chrX 1687 1700 + into chrX 1600 instead
    df = by(df, [:Chromosome, :Strand], x -> bin_positions(x, half_fragment_size, args["chromosome_sizes"]))
    # remove strand
    df = df[[1, 3]]

    lvl = sort(unique(df[1]), lt=NaturalSort.natural)
    levels!(df[1], lvl)

    return df

end


function merge_nearby_bins(df, gaps_allowed, bin_size, score_threshold)

    bin_size_minus_one = bin_size - 1

    distance_allowed = (gaps_allowed * bin_size) + 2

    if nrow(df) == 1
        return df
    end

    current_island = df[1, :]

    merged_islands = similar(df, 0)

    # just to have exact same result as SICER
    slightly_less = score_threshold - 0.0000000001

    for idx in 2:nrow(df)
        dist = df[idx, :Start] - current_island[1, :End]
        if dist <= distance_allowed
            current_island[:End] = df[idx, :End]
            current_island[1, :Score] += df[idx, :Score]
            current_island[1, :Count] += df[idx, :Count]
            current_island[1, :InputCount] += df[idx, :InputCount]
        else
            if current_island[1, :Score] > slightly_less
                append!(merged_islands, current_island[:])
            end
            current_island = df[idx, :]
        end

    end

    if current_island[1, :Score] > slightly_less

        append!(merged_islands, current_island[:])
    end

    delete!(merged_islands, 1)

end


function merge_nearby_bins_no_input(df, gaps_allowed, bin_size, score_threshold)

    bin_size_minus_one = bin_size - 1

    distance_allowed = (gaps_allowed * bin_size) + 2

    if nrow(df) == 1
        return df
    end

    current_island = df[1, :]

    merged_islands = similar(df, 0)

    # just to have exact same result as SICER
    slightly_less = score_threshold - 0.0000000001

    for idx in 2:nrow(df)
        dist = df[idx, :Start] - current_island[1, :End]
        if dist <= distance_allowed
            current_island[:End] = df[idx, :End]
            current_island[1, :Score] += df[idx, :Score]
            current_island[1, :Count] += df[idx, :Count]
        else
            if current_island[1, :Score] > slightly_less
                append!(merged_islands, current_island[:])
            end
            current_island = df[idx, :]
        end

    end

    if current_island[1, :Score] > slightly_less

        append!(merged_islands, current_island[:])
    end

    delete!(merged_islands, 1)

end

function sicer_w_input(args)
  chip_df = vcat(map(x -> df_to_bins(x, args), args["chip"])...)
  chip_df = by(chip_df, [:Chromosome, :Bin], x -> DataFrame(Count=nrow(x)), sort=true)


  input_df = vcat(map(x -> df_to_bins(x, args), args["input"])...)
  input_df = by(input_df, [:Chromosome, :Bin], x -> DataFrame(Count=nrow(x)), sort=true)

  total_chip_count = sum(chip_df.Count)
  total_input_count = sum(input_df.Count)

  score_threshold, island_enriched_threshold, average_window_readcount = compute_background_probabilities(
      total_chip_count, args["bin_size"], args["effective_genome_fraction"], args["gaps_allowed"])

  chip_df = give_bins_pvalues(chip_df, island_enriched_threshold, average_window_readcount)

  df = join(chip_df, input_df, on=[:Chromosome, :Bin], kind=:left)
  rename!(df, [:Count_1 => :InputCount])
  missing_input = ismissing.(df[:InputCount])
  df[missing_input, :InputCount] = 0


  rename!(df, [:Bin => :Start])
  df[:End] = df[:Start] .+ args["bin_size"] .- 1
  df[:Score] = -log.(df[:Score])

  result = by(df, [:Chromosome], x -> merge_nearby_bins(x, args["gaps_allowed"], args["bin_size"], score_threshold))

  result = result[[:Chromosome, :Start, :End, :Count, :InputCount, :Score]]

  fdr_df = give_islands_fdr_score(result, total_chip_count, total_input_count, args["effective_genome_fraction"])

  CSV.write(args["outfile"], fdr_df, delim='\t')

end


function sicer_wout_input(args)
  chip_df = vcat(map(x -> df_to_bins(x, args), args["chip"])...)
  chip_df = by(chip_df, [:Chromosome, :Bin], x -> DataFrame(Count=nrow(x)))


  total_chip_count = sum(chip_df.Count)

  score_threshold, island_enriched_threshold, average_window_readcount = compute_background_probabilities(
      total_chip_count, args["bin_size"], args["effective_genome_fraction"], args["gaps_allowed"])

  df = give_bins_pvalues(chip_df, island_enriched_threshold, average_window_readcount)

  rename!(df, [:Bin => :Start])
  df[:End] = df[:Start] .+ args["bin_size"] .- 1
  df[:Score] = -log.(df[:Score])

  result = by(df, [:Chromosome], x -> merge_nearby_bins_no_input(x, args["gaps_allowed"], args["bin_size"], score_threshold))

  result = result[[:Chromosome, :Start, :End, :Count, :Score]]
  result[:Score] = 1 ./ exp.(result[:Score])

  result[:Score] = adjust(result[:Score], BenjaminiHochberg())
  rename!(result, [:Score => :FDR])

  CSV.write(args["outfile"], result, delim='\t')

end


function bam_to_df(f, nrows)

    df = DataFrame(Chromosome = String[], Start = Int64[], End = Int64[], Name = Int64[], Score = Int64[], Strand = String[])

    # include max number of rows to read - how?
    counter = 0

    for alignment in open(BAM.Reader, f)
        if BAM.ismapped(alignment)
            lpos = BAM.position(alignment) - 1
            rpos = lpos + BAM.alignlength(alignment)

            if BAM.flag(alignment) & 0 == 0
                strand = "+"
            else
                strand = "-"
            end

            push!(df, [BAM.refname(alignment), lpos, rpos, 0, 0, strand])
        end
    end

    df[1] = CategoricalArray(df[1])
    df[6] = CategoricalArray(df[6])

    df

end


function file_to_df(f, nrows=nothing)
    if endswith(f, ".bam")
        bam_to_df(f, nrows)
    else
        CSV.read(f, delim="\t", header=["Chromosome", "Start", "End", "Name", "Score", "Strand"], categorical=true, limit=nrows)
    end
end






Base.@ccallable function julia_main(ARGS::Vector{String})::Cint

    args = parse_commandline()
    println(args["chromosome_sizes"][1])
    df = args["chromosome_sizes"]
    args["chromosome_sizes"] = Dict(zip(df[1], df[2]))

    println("outfile ", args["outfile"])
    if !isempty(args["input"])
        sicer_w_input(args)
    else
        sicer_wout_input(args)
    end

    return 0

end

julia_main([""])
