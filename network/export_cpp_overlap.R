library(igraph)
library(psych)
library(WGCNA)
library(OTUtable)
library(microbiome)
library(ggClusterNet)
library(tidyverse)
library(ggnewscale)
# 导入数据
otu_s <- read_tsv("../tax_count.S.norm")
otu_p <- read_csv("../tax_count.P.norm.csv")
otu_g <- read_csv("../tax_count.G.norm.csv")
group <- read_tsv("../metadata.txt") %>%
    column_to_rownames("SampleID") %>%
    sample_data()
# r cutoff可选择MENA推荐的值,也可都设为0.6;出图的区别不大
# r_cut <- c(0.51, 0.51, 0.43, 0.33, 0.46, 0.68, 0.41, 0.33)
r_cut <- rep(0.6, 8)
group_list <- c(
    "Meth_Acq", "Meth_Ext", "Meth_Pre", "Meth_Rein",
    "Sal_Acq", "Sal_Ext", "Sal_Pre", "Sal_Rein"
)
cpp_s <- read_tsv("./species_cpp_p0.05.txt") %>%
    filter(p <= 0.05, abs(r) >= 0.6) %>%
    select(species)
cpp_p <- read_tsv("./phylum_cpp_p0.05.txt") %>%
    filter(p <= 0.05, abs(r) >= 0.6) %>%
    select(phylum)
cpp_g <- read_tsv("./genus_cpp_p0.05.txt") %>%
    filter(p <= 0.05, abs(r) >= 0.6) %>%
    select(genus)
#------------------------------------------------------#
# 主要的函数
#------------------------------------------------------#
get_network <- function(otu, group, i, r_cut, cpp) {
    otu_relative <- transform(otu %>% column_to_rownames("Taxonomy"), transform = "compositional")
    otu <- otu %>%
        filter(Taxonomy %in%
            (OTUtable::filter_taxa(otu_relative, abundance = 0.01, persistence = 3) %>% rownames())) %>%
        column_to_rownames("Taxonomy") %>%
        otu_table(taxa_are_rows = TRUE)
    physeq <- phyloseq(otu, group) # 转为phyloseq格式
    physeq <- prune_samples(x = physeq, !grepl(".*Rein00[5-9]", sample_names(physeq))) # 去除Rein005-Rein009的样本
    group_list <- c(
        "Meth_Acq", "Meth_Ext", "Meth_Pre", "Meth_Rein",
        "Sal_Acq", "Sal_Ext", "Sal_Pre", "Sal_Rein"
    )
    i <- group_list[i] # 获取第i个组
    oldDF <- as(sample_data(physeq), "data.frame")
    newDF <- subset(oldDF, Group == i)
    sample_data(physeq) <- sample_data(newDF)
    # physeq <- subset_samples(physeq,Group == i) 这个函数有问题,弃之
    # 计算相关性
    result <- cor_Big_micro(
        ps = physeq,
        N = nrow(otu),
        r.threshold = r_cut,
        p.threshold = 0.05,
        method = "spearman"
    )
    cor <- result[[1]]
    table(cor[cor > 0])

    #--提取相关矩阵
    model_igraph.2 <- function(cor = cor, method = "cluster_fast_greedy", seed = 12,
                               Top_M = 20) {
        igraph <- graph.adjacency(cor, weighted = TRUE, mode = "undirected")
        igraph <- simplify(igraph)
        bad.vs <- V(igraph)[degree(igraph) == 0]
        igraph <- delete.vertices(igraph, bad.vs)

        col_g <- "#C1C1C1"
        cols <- colorRampPalette(RColorBrewer::brewer.pal(11, "Spectral"))(Top_M)
        E(igraph)$correlation <- E(igraph)$weight
        E(igraph)$weight <- abs(E(igraph)$weight)
        set.seed(seed)
        if (method == "cluster_walktrap") {
            fc <- cluster_walktrap(igraph, weights = abs(E(igraph)$weight))
        }
        if (method == "cluster_edge_betweenness") {
            fc <- cluster_edge_betweenness(igraph, weights = abs(E(igraph)$weight))
        }
        if (method == "cluster_fast_greedy") {
            fc <- cluster_fast_greedy(igraph, weights = abs(E(igraph)$weight))
        }
        if (method == "cluster_spinglass") {
            fc <- cluster_spinglass(igraph, weights = abs(E(igraph)$weight))
        }
        V(igraph)$modularity <- membership(fc)
        V(igraph)$label <- V(igraph)$name
        V(igraph)$label <- NA
        modu_sort <- V(igraph)$modularity %>%
            table() %>%
            sort(decreasing = T)
        top_num <- Top_M
        modu_name <- names(modu_sort[1:Top_M])
        modu_cols <- cols[1:length(modu_name)]
        names(modu_cols) <- modu_name
        V(igraph)$color <- V(igraph)$modularity
        V(igraph)$color[!(V(igraph)$color %in% modu_name)] <- col_g
        V(igraph)$color[(V(igraph)$color %in% modu_name)] <- modu_cols[match(V(igraph)$color[(V(igraph)$color %in%
            modu_name)], modu_name)]
        V(igraph)$frame.color <- V(igraph)$color
        E(igraph)$color <- col_g
        for (i in modu_name) {
            col_edge <- cols[which(modu_name == i)]
            otu_same_modu <- V(igraph)$name[which(V(igraph)$modularity ==
                i)]
            E(igraph)$color[(data.frame(as_edgelist(igraph))$X1 %in%
                otu_same_modu) & (data.frame(as_edgelist(igraph))$X2 %in%
                otu_same_modu)] <- col_edge
        }
        sub_net_layout <- layout_with_fr(igraph, niter = 999, grid = "nogrid")
        data <- as.data.frame(sub_net_layout)
        data$OTU <- igraph::get.vertex.attribute(igraph)$name
        colnames(data) <- c("X1", "X2", "elements")
        tem <- V(igraph)$modularity
        tem[!tem %in% modu_name] <- "mini_model"
        tem[tem %in% modu_name] <- paste("model_", tem[tem %in% modu_name],
            sep = ""
        )
        row.names(data) <- data$elements
        dat <- data.frame(
            orig_model = V(igraph)$modularity, model = tem,
            color = V(igraph)$color, OTU = igraph::get.vertex.attribute(igraph)$name,
            X1 = data$X1, X2 = data$X2
        )
        return(list(data, dat, igraph))
    }
    result2 <- model_igraph.2(
        cor = cor,
        method = "cluster_fast_greedy",
        seed = 12
    )
    # 添加domain, phylum, cpp交集
    dat <- result2[[2]]
    overlap <- intersect(dat$OTU, cpp[,1] %>%as_vector())
    # browser()
    overlap
}
wrap_levels <- function(otu,group,r_cut,cpp,fname) {
    total_list <- list(
        rep(list(otu), 8), rep(list(group), 8), 1:8,
        r_cut, rep(list(cpp), 8)
    )
    # get_network(otu = otu, group = group, physeq = ps, i = 1, r_cut = r_cut[1], cpp = cpp)
    overlap <- pmap(total_list, get_network)
    names(overlap) <- group_list
    temp <- plyr::ldply(overlap, rbind) %>% as_tibble()
    write_csv(temp, paste0("./result/overlap/overlap_", fname, ".csv"))
}
wrap_levels(otu = otu_s, group = group,r_cut = r_cut, cpp = cpp_s,fname="s")
wrap_levels(otu = otu_p, group = group,r_cut = r_cut, cpp = cpp_p,fname="p")
wrap_levels(otu = otu_g, group = group,r_cut = r_cut, cpp = cpp_g,fname="g")

