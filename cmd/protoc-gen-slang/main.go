package main

import (
	"fmt"
	"io"
	"os"
)

const maxPluginBytes = 64 << 20

func main() {
	input, err := io.ReadAll(io.LimitReader(os.Stdin, maxPluginBytes+1))
	if err != nil {
		writeResponse(nil, err)
		return
	}
	if len(input) > maxPluginBytes {
		writeResponse(nil, fmt.Errorf("CodeGeneratorRequest exceeds 64 MiB"))
		return
	}
	filesToGenerate, files, err := parseRequest(input)
	if err == nil {
		var output []generatedFile
		output, err = generate(filesToGenerate, files)
		writeResponse(output, err)
		return
	}
	writeResponse(nil, err)
}

type generatedFile struct {
	name, content string
}

func writeResponse(files []generatedFile, err error) {
	var response []byte
	if err != nil {
		response = appendStringField(response, 1, err.Error())
		response = appendVarint(response, 2<<3)
		response = appendVarint(response, 1) // FEATURE_PROTO3_OPTIONAL
		_, _ = os.Stdout.Write(response)
		return
	}
	response = appendVarint(response, 2<<3)
	response = appendVarint(response, 1) // FEATURE_PROTO3_OPTIONAL
	for _, file := range files {
		var encoded []byte
		encoded = appendStringField(encoded, 1, file.name)
		encoded = appendStringField(encoded, 15, file.content)
		response = appendBytesField(response, 15, encoded)
	}
	_, _ = os.Stdout.Write(response)
}
