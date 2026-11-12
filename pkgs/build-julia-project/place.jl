# SPDX-License-Identifier: MIT
#
# Puts each package source of a download tree at the depot path where
# Julia looks for it, packages/<Name>/<slug>, and prints the depot paths of
# the packages that the project's manifest pins and that have a
# deps/build.jl.
#
# Usage: julia place.jl <download tree> <depot> <placements file>
#
# Each line of the placements file is "<name> <uuid> <tree> <source> <main>",
# with <source> a path in the download tree and <main> "1" for a package of
# the project's manifest. The slug is the one Julia derives from the UUID
# and the tree hash.
downloads, depot, placements = ARGS

builds = Set{String}()
for line in eachline(placements)
    isempty(line) && continue
    name, uuid, tree, source, main = split(line, ' ')
    slug = Base.version_slug(Base.UUID(uuid), Base.SHA1(tree))
    path = "packages/$(name)/$(slug)"
    target = joinpath(depot, path)
    if !ispath(target)
        mkpath(dirname(target))
        cp(joinpath(downloads, source), target; follow_symlinks = true)
    end
    main == "1" && isfile(joinpath(target, "deps", "build.jl")) && push!(builds, path)
end
foreach(println, sort(collect(builds)))
