library(ggplot2)
p <- ggplot(mtcars, aes(x = wt, y = mpg)) + geom_point()
ggsave("gallery/scatter/ggplot.pdf", p, width = 6, height = 4)   # points; cairo not needed
