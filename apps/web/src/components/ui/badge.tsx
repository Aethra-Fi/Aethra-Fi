import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";

import { cn } from "@/lib/utils";

const badgeVariants = cva(
  "inline-flex items-center gap-1.5 whitespace-nowrap rounded-sm px-1.5 py-0.5 font-mono text-[10px] font-medium uppercase leading-4 tracking-[0.14em]",
  {
    variants: {
      variant: {
        default: "bg-primary-soft text-primary-text",
        accent: "bg-accent-soft text-accent-text",
        warning: "bg-warning-soft text-warning",
        danger: "bg-danger-soft text-danger",
        neutral: "bg-surface-2 text-muted",
        outline: "border border-border-strong text-fg-2",
        secondary: "bg-surface-2 text-fg-2",
        destructive: "bg-danger-soft text-danger",
      },
    },
    defaultVariants: { variant: "default" },
  },
);

export interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement>, VariantProps<typeof badgeVariants> {}

function Badge({ className, variant, ...props }: BadgeProps) {
  return <span className={cn(badgeVariants({ variant }), className)} {...props} />;
}

export { Badge, badgeVariants };
